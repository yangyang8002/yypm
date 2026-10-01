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

    static void run() throws Exception {
        diag("sdk=" + sdkInt());

        Object ipm = ipm();
        diag("ipm=" + ipm.getClass().getName());

        Object slice = ipm.getClass()
                .getMethod("getInstalledPackages", int.class, int.class)
                .invoke(ipm, Integer.valueOf(GET_META_DATA), Integer.valueOf(0));
        diag("slice=" + slice.getClass().getName());

        List<?> list = (List<?>) slice.getClass().getMethod("getList").invoke(slice);
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
