package com.yypm.appinfo;

/*
 * AppInfo —— 以 root 身份跑在 app_process 里，借用系统自身的包管理服务拿到
 * 「全部应用 + 本地化应用名 + 图标 + LSPosed 模块标记」。
 *
 * 为什么不靠 ActivityThread.systemMain()：
 *   上一版把"拿系统 Context"当作唯一出路，结果在真机上直接没输出。
 *   这里改成完全不需要 Context：
 *     - 包列表：ActivityThread.getPackageManager() 拿 IPackageManager（走 ServiceManager，
 *       不依赖 ActivityThread 初始化，root 不受包可见性限制）
 *     - 应用名/图标：自己给每个 APK 建一个 Resources（AssetManager.addAssetPath），
 *       由框架的资源系统解析 labelRes / icon，拿到本地化名字和真实图标
 *   这样任何一步失败都能单独降级，不会整条路一起死。
 *
 * 全部用反射写，所以编译时不需要 android.jar：javac --release 11 + d8 即可。
 *
 * 输出（stdout，UTF-8，TAB 分隔）：pkg \t label \t tags
 * 诊断信息走 stderr（调用方把它存到 appinfo.err）。
 * 结束行 #mode=... 是给 shell 认的成功标记。
 */
import java.io.File;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.PrintStream;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public class AppInfo {

    static final int GET_META_DATA = 0x00000080;
    static final int FLAG_SYSTEM = 0x00000001;
    static final int FLAG_UPDATED_SYSTEM_APP = 0x00000080;

    static PrintStream out;
    static PrintStream err;

    static Class<?> cRes, cAM, cDM, cCfg, cAI;
    static final Map<String, Object> RES_CACHE = new HashMap<String, Object>();

    static String iconDir = null;
    static int iconSize = 96;
    static int iconOk = 0, iconFail = 0;
    static String mode = "ipm";

    public static void main(String[] args) {
        try {
            out = new PrintStream(new FileOutputStream(FileDescriptor.out), true, "UTF-8");
        } catch (Throwable t) {
            out = System.out;
        }
        err = System.err;

        for (int i = 0; i < args.length; i++) {
            if ("--icons".equals(args[i]) && i + 1 < args.length) {
                iconDir = args[++i];
            } else if ("--icon-size".equals(args[i]) && i + 1 < args.length) {
                try { iconSize = Integer.parseInt(args[++i]); } catch (Throwable ignored) { }
            }
        }

        // 位置参数（命令模式）：lspd-enable <db路径> <模块包名> <scope包名>
        // —— 直写 LSPosed modules_config.db：启用模块 + scope 加「系统框架」。
        List<String> pos = new ArrayList<String>();
        for (int i = 0; i < args.length; i++) {
            if ("--icons".equals(args[i]) || "--icon-size".equals(args[i])) { i++; continue; }
            if (args[i].startsWith("--")) { continue; }
            pos.add(args[i]);
        }
        if (pos.size() >= 4 && "lspd-enable".equals(pos.get(0))) {
            int lrc = 0;
            try {
                lspdEnable(pos.get(1), pos.get(2), pos.get(3));
            } catch (Throwable t) {
                out.println("LSPD=FAIL(" + t.getClass().getSimpleName() + ": " + t.getMessage() + ")");
                lrc = 2;
            }
            out.println("#mode=lspd");
            out.flush();
            System.exit(lrc);
            return;
        }

        int code = 0;
        try {
            run();
        } catch (Throwable t) {
            err.println("ERROR=" + t.getClass().getName() + ": " + t.getMessage());
            t.printStackTrace(err);
            code = 2;
        }
        out.flush();
        // 必须显式退出：app_process 里的 binder 线程是非 daemon 的，
        // main() 返回后进程不会自己结束，调用方的 $(...) 会一直等 EOF。
        System.exit(code);
    }

    // ---- LSPosed modules_config.db 直写（「一键配置 FuseFixer」用）----
    // 全反射（编译期不需要 android.jar）。风险边界：只 UPDATE enabled、
    // INSERT OR IGNORE 一行 scope；模块行不存在就放弃（LSPosed 扫到 APK 后
    // 自己会建行），绝不重建表、绝不删数据。失败输出 LSPD=FAIL(原因)。
    static void lspdEnable(String dbPath, String modulePkg, String scopePkg) throws Exception {
        Class<?> cDb = Class.forName("android.database.sqlite.SQLiteDatabase");
        Class<?> cCf = Class.forName("android.database.sqlite.SQLiteDatabase$CursorFactory");
        Object db = cDb.getMethod("openDatabase", String.class, cCf, int.class)
                .invoke(null, dbPath, null, Integer.valueOf(0)); // 0 = OPEN_READWRITE
        try {
            List<String> modCols = tableColumns(db, "modules");
            List<String> scopeCols = tableColumns(db, "scope");
            if (modCols.isEmpty() || scopeCols.isEmpty()) {
                out.println("LSPD=FAIL(schema 不含 modules/scope 表)");
                return;
            }
            boolean modern = modCols.contains("mid");
            out.println("LSPD_SCHEMA=" + (modern ? "mid 外键版" : "包名直联版"));
            String mid = null;
            if (modern) {
                List<String[]> r = queryRows(db,
                        "SELECT mid, enabled FROM modules WHERE module_pkg_name=?",
                        new String[]{modulePkg}, 2);
                if (r.isEmpty()) {
                    out.println("LSPD=FAIL(模块行不存在——先打开一次 LSPosed 管理器让它扫到该模块，再点本按钮)");
                    return;
                }
                mid = r.get(0)[0];
                if (!"1".equals(r.get(0)[1])) {
                    execSql(db, "UPDATE modules SET enabled=1 WHERE mid=?", new Object[]{Long.valueOf(mid)});
                }
                if (scopeCols.contains("user_id")) {
                    execSql(db, "INSERT OR IGNORE INTO scope (mid, app_pkg_name, user_id) VALUES (?,?,0)",
                            new Object[]{Long.valueOf(mid), scopePkg});
                } else {
                    execSql(db, "INSERT OR IGNORE INTO scope (mid, app_pkg_name) VALUES (?,?)",
                            new Object[]{Long.valueOf(mid), scopePkg});
                }
            } else {
                List<String[]> r = queryRows(db,
                        "SELECT enabled FROM modules WHERE module_pkg_name=?",
                        new String[]{modulePkg}, 1);
                if (r.isEmpty()) {
                    out.println("LSPD=FAIL(模块行不存在——先打开一次 LSPosed 管理器让它扫到该模块，再点本按钮)");
                    return;
                }
                execSql(db, "UPDATE modules SET enabled=1 WHERE module_pkg_name=?", new Object[]{modulePkg});
                execSql(db, "INSERT OR IGNORE INTO scope (module_pkg_name, app_pkg_name) VALUES (?,?)",
                        new Object[]{modulePkg, scopePkg});
            }
            out.println("LSPD=OK");
            out.println("LSPD_MODULE=" + modulePkg + (mid != null ? ("(mid=" + mid + ")") : ""));
            out.println("LSPD_SCOPE_ADDED=" + scopePkg);
            out.println("LSPD_REBOOT=1");
        } finally {
            try { db.getClass().getMethod("close").invoke(db); } catch (Throwable ignored) { }
        }
    }

    static List<String> tableColumns(Object db, String table) throws Exception {
        List<String> cols = new ArrayList<String>();
        Object cur = db.getClass().getMethod("rawQuery", String.class, String[].class)
                .invoke(db, "PRAGMA table_info(" + table + ")", (Object) null);
        try {
            Method mNext = cur.getClass().getMethod("moveToNext");
            Method mStr = cur.getClass().getMethod("getString", int.class);
            while (((Boolean) mNext.invoke(cur)).booleanValue()) {
                cols.add((String) mStr.invoke(cur, Integer.valueOf(1))); // name 列
            }
        } finally {
            try { cur.getClass().getMethod("close").invoke(cur); } catch (Throwable ignored) { }
        }
        return cols;
    }

    static List<String[]> queryRows(Object db, String sql, String[] args, int ncols) throws Exception {
        List<String[]> rows = new ArrayList<String[]>();
        Object cur = db.getClass().getMethod("rawQuery", String.class, String[].class)
                .invoke(db, sql, (Object) args);
        try {
            Method mNext = cur.getClass().getMethod("moveToNext");
            Method mStr = cur.getClass().getMethod("getString", int.class);
            while (((Boolean) mNext.invoke(cur)).booleanValue()) {
                String[] row = new String[ncols];
                for (int i = 0; i < ncols; i++) {
                    row[i] = (String) mStr.invoke(cur, Integer.valueOf(i));
                }
                rows.add(row);
            }
        } finally {
            try { cur.getClass().getMethod("close").invoke(cur); } catch (Throwable ignored) { }
        }
        return rows;
    }

    static void execSql(Object db, String sql, Object[] args) throws Exception {
        db.getClass().getMethod("execSQL", String.class, Object[].class).invoke(db, sql, (Object) args);
    }

    static void run() throws Exception {
        diag("sdk=" + sdkInt());

        Object ipm = ipm();
        diag("ipm=" + ipm.getClass().getName());

        Object slice = callIpm(ipm, "getInstalledPackages", GET_META_DATA, 0);
        diag("slice=" + slice.getClass().getName());

        // 有的版本直接返回 List，有的返回 ParceledListSlice，两种都认
        List<?> list;
        if (slice instanceof List) {
            list = (List<?>) slice;
        } else {
            list = (List<?>) slice.getClass().getMethod("getList").invoke(slice);
        }
        diag("count=" + (list == null ? -1 : list.size()));
        if (list == null) {
            throw new IllegalStateException("getInstalledPackages 返回 null");
        }

        cAI = Class.forName("android.content.pm.ApplicationInfo");
        Field fAppInfo = null;
        Field fPkg = cAI.getField("packageName");
        Field fLabelRes = cAI.getField("labelRes");
        Field fNonLoc = cAI.getField("nonLocalizedLabel");
        Field fFlags = cAI.getField("flags");
        Field fMeta = cAI.getField("metaData");
        Field fSrc = fieldOrNull(cAI, "sourceDir");
        Field fIcon = fieldOrNull(cAI, "icon");
        // API 26+ 才有；CATEGORY_GAME == 0，反挂的 LSPosed 作用域分析靠它认出游戏
        Field fCategory = fieldOrNull(cAI, "category");

        Class<?> cBundle = Class.forName("android.os.Bundle");
        Method bGetBool = cBundle.getMethod("getBoolean", String.class);
        Method bGetStr = cBundle.getMethod("getString", String.class);

        int n = 0, named = 0;
        for (Object pi : list) {
            if (pi == null) {
                continue;
            }
            try {
                if (fAppInfo == null) {
                    fAppInfo = pi.getClass().getField("applicationInfo");
                }
                Object ai = fAppInfo.get(pi);
                if (ai == null) {
                    continue;
                }
                String pkg = (String) fPkg.get(ai);
                if (pkg == null) {
                    continue;
                }

                String src = (fSrc == null) ? null : (String) fSrc.get(ai);

                // ---- 应用名：优先框架解析（本地化），退回 nonLocalizedLabel ----
                CharSequence label = null;
                Object res = (src == null) ? null : resourcesFor(src);
                if (res != null) {
                    int lr = fLabelRes.getInt(ai);
                    if (lr != 0) {
                        try {
                            label = (CharSequence) cRes.getMethod("getText", int.class).invoke(res, Integer.valueOf(lr));
                        } catch (Throwable ignored) {
                        }
                    }
                }
                if (label == null) {
                    label = (CharSequence) fNonLoc.get(ai);
                }
                if (label == null) {
                    label = "";
                }
                if (label.length() > 0) {
                    named++;
                }

                // ---- 图标：尽力而为，失败绝不影响列表 ----
                if (iconDir != null && res != null && fIcon != null) {
                    try {
                        int ir = fIcon.getInt(ai);
                        if (ir != 0) {
                            writeIcon(res, ir, pkg);
                        } else {
                            iconFail++;
                        }
                    } catch (Throwable t) {
                        iconFail++;
                    }
                }

                // ---- 标记 ----
                StringBuilder tags = new StringBuilder();
                int flags = fFlags.getInt(ai);
                if ((flags & (FLAG_SYSTEM | FLAG_UPDATED_SYSTEM_APP)) != 0) {
                    tags.append("system");
                }
                if (fCategory != null) {
                    try {
                        if (fCategory.getInt(ai) == 0) {   // CATEGORY_GAME
                            if (tags.length() > 0) {
                                tags.append(',');
                            }
                            tags.append("game");
                        }
                    } catch (Throwable ignored) {
                    }
                }
                Object meta = null;
                try { meta = fMeta.get(ai); } catch (Throwable ignored) { }
                if (meta != null) {
                    try {
                        Object v = bGetBool.invoke(meta, "xposedmodule");
                        if (v instanceof Boolean && ((Boolean) v).booleanValue()) {
                            if (tags.length() > 0) {
                                tags.append(',');
                            }
                            tags.append("xposed");
                            Object d = bGetStr.invoke(meta, "xposeddescription");
                            if (d instanceof String && ((String) d).length() > 0) {
                                tags.append(",desc=").append(clean((String) d));
                            }
                        }
                    } catch (Throwable ignored) {
                    }
                }

                out.println(clean(pkg) + "\t" + clean(label.toString()) + "\t" + tags);
                n++;
            } catch (Throwable t) {
                diag("skip pkg: " + t.getClass().getSimpleName() + " " + t.getMessage());
            }
        }
        out.println("#mode=" + mode + " count=" + n + " named=" + named
                + " icons=" + iconOk + "/" + (iconOk + iconFail));
    }

    /** ActivityThread.getPackageManager() 走 ServiceManager，不需要 Context */
    /**
     * 调 IPackageManager 上「签名随版本变过」的方法。
     *
     * 踩过的坑：Android 16 (SDK 36) 把 getInstalledPackages 的 flags 参数从 int 改成了 long，
     * 硬写 getMethod(name, int.class, int.class) 会直接 NoSuchMethodException —— 而且报错
     * 长得像"方法不存在"，很容易误判成权限或 API 被砍。
     *
     * 所以这里不写死签名：按名字 + 参数形态（第 1 个是 int/long，可选第 2 个 int）去匹配，
     * 匹配到谁就用谁，调用时按参数类型装箱。这样下次再改也不用跟着改代码。
     */
    static Object callIpm(Object ipm, String name, int flags, int userId) throws Exception {
        Method best = null;
        for (Method m : ipm.getClass().getMethods()) {
            if (!m.getName().equals(name)) {
                continue;
            }
            Class<?>[] p = m.getParameterTypes();
            if (p.length < 1 || p.length > 2) {
                continue;
            }
            if (p[0] != int.class && p[0] != long.class) {
                continue;
            }
            if (p.length == 2 && p[1] != int.class) {
                continue;
            }
            best = m;
            break;
        }
        if (best == null) {
            // 一个都没匹配上：把系统里真实存在的方法名列出来，下次就不用猜了
            for (Method m : ipm.getClass().getMethods()) {
                if (m.getName().toLowerCase().contains("installed")) {
                    StringBuilder sb = new StringBuilder();
                    for (Class<?> c : m.getParameterTypes()) {
                        sb.append(sb.length() == 0 ? "" : ",").append(c.getName());
                    }
                    diag("avail " + m.getName() + "(" + sb + ")");
                }
            }
            throw new NoSuchMethodException(name);
        }
        Class<?>[] p = best.getParameterTypes();
        Object f = (p[0] == long.class) ? (Object) Long.valueOf(flags) : (Object) Integer.valueOf(flags);
        Object[] argv = (p.length == 2) ? new Object[] { f, Integer.valueOf(userId) } : new Object[] { f };
        StringBuilder sb = new StringBuilder();
        for (Class<?> c : p) {
            sb.append(sb.length() == 0 ? "" : ",").append(c.getName());
        }
        diag("call " + name + "(" + sb + ")");
        return best.invoke(ipm, argv);
    }

    static Object ipm() throws Exception {
        Class<?> cAT = Class.forName("android.app.ActivityThread");
        Object ipm = cAT.getMethod("getPackageManager").invoke(null);
        if (ipm == null) {
            throw new IllegalStateException("getPackageManager 返回 null");
        }
        return ipm;
    }

    /** 给一个 APK 建 Resources（按路径缓存），由框架解析 labelRes / icon */
    static Object resourcesFor(String apkPath) {
        Object cached = RES_CACHE.get(apkPath);
        if (cached != null) {
            return cached;
        }
        try {
            if (cAM == null) {
                cAM = Class.forName("android.content.res.AssetManager");
                cDM = Class.forName("android.util.DisplayMetrics");
                cCfg = Class.forName("android.content.res.Configuration");
                cRes = Class.forName("android.content.res.Resources");
            }
            Object am = cAM.getDeclaredConstructor().newInstance();
            cAM.getMethod("addAssetPath", String.class).invoke(am, apkPath);
            Object dm = cDM.getDeclaredConstructor().newInstance();
            Object cfg = cCfg.getDeclaredConstructor().newInstance();
            Object res = cRes.getConstructor(cAM, cDM, cCfg).newInstance(am, dm, cfg);
            RES_CACHE.put(apkPath, res);
            return res;
        } catch (Throwable t) {
            if (RES_CACHE.size() < 3) {
                diag("resources fail: " + t.getClass().getSimpleName() + " " + t.getMessage());
            }
            RES_CACHE.put(apkPath, Boolean.FALSE);
            return null;
        }
    }

    /** 把 Drawable 渲染成 PNG 落盘。自适应图标也走 setBounds + draw，能正常出图。 */
    static void writeIcon(Object res, int iconRes, String pkg) throws Exception {
        File dir = new File(iconDir);
        if (!dir.isDirectory() && !dir.mkdirs()) {
            throw new IllegalStateException("无法创建图标目录");
        }
        File f = new File(dir, pkg + ".png");
        if (f.isFile() && f.length() > 0) {   // 已有就跳过，第二次扫描会快很多
            iconOk++;
            return;
        }

        Object d;
        try {
            d = cRes.getMethod("getDrawable", int.class).invoke(res, Integer.valueOf(iconRes));
        } catch (Throwable t) {
            Class<?> cTheme = Class.forName("android.content.res.Resources$Theme");
            d = cRes.getMethod("getDrawable", int.class, cTheme).invoke(res, Integer.valueOf(iconRes), null);
        }
        if (d == null) {
            iconFail++;
            return;
        }

        Class<?> cBitmap = Class.forName("android.graphics.Bitmap");
        Class<?> cConfig = Class.forName("android.graphics.Bitmap$Config");
        Object cfg = cConfig.getMethod("valueOf", String.class).invoke(null, "ARGB_8888");
        Object bmp = cBitmap.getMethod("createBitmap", int.class, int.class, cConfig)
                .invoke(null, Integer.valueOf(iconSize), Integer.valueOf(iconSize), cfg);

        Class<?> cCanvas = Class.forName("android.graphics.Canvas");
        Object canvas = cCanvas.getConstructor(cBitmap).newInstance(bmp);

        Class<?> cDrawable = Class.forName("android.graphics.drawable.Drawable");
        cDrawable.getMethod("setBounds", int.class, int.class, int.class, int.class)
                .invoke(d, Integer.valueOf(0), Integer.valueOf(0), Integer.valueOf(iconSize), Integer.valueOf(iconSize));
        cDrawable.getMethod("draw", cCanvas).invoke(d, canvas);

        Class<?> cFmt = Class.forName("android.graphics.Bitmap$CompressFormat");
        Object png = cFmt.getMethod("valueOf", String.class).invoke(null, "PNG");
        FileOutputStream fos = new FileOutputStream(f);
        try {
            cBitmap.getMethod("compress", cFmt, int.class, Class.forName("java.io.OutputStream"))
                    .invoke(bmp, png, Integer.valueOf(90), fos);
        } finally {
            fos.close();
        }
        try { cBitmap.getMethod("recycle").invoke(bmp); } catch (Throwable ignored) { }
        iconOk++;
    }

    static int sdkInt() {
        try {
            return Class.forName("android.os.Build$VERSION").getField("SDK_INT").getInt(null);
        } catch (Throwable t) {
            return -1;
        }
    }

    static Field fieldOrNull(Class<?> c, String name) {
        try {
            return c.getField(name);
        } catch (Throwable t) {
            return null;
        }
    }

    static void diag(String s) {
        err.println("#diag " + s);
    }

    /** 压掉 TAB / 换行 / 回车，避免破坏 TSV 结构 */
    static String clean(String s) {
        if (s == null) {
            return "";
        }
        StringBuilder b = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '\t' || c == '\n' || c == '\r') {
                b.append(' ');
            } else {
                b.append(c);
            }
        }
        return b.toString().trim();
    }
}
