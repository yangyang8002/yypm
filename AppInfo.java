/*
 * AppInfo —— 以 root 身份跑在 app_process 里，借用系统自身的 PackageManager
 * 一次拿到「全部应用 + 本地化应用名 + LSPosed 模块标记」。
 *
 * 为什么这样做：
 *   - Android 11+ 的包可见性限制（<queries> / QUERY_ALL_PACKAGES）只约束普通应用；
 *     root 进程本来就无视它（pm list packages 现在就能列全）。
 *     真正拿不到的是「应用名」——它只存在 APK 的 resources.arsc 里，
 *     pm / dumpsys 只输出 labelRes=0x7f... 这种资源 id。
 *   - 让系统自己解析是最省的：systemMain() 拿到系统 Context，
 *     getApplicationLabel() 由框架的资源系统直接给出本地化名字，几乎零 I/O。
 *   - 全部用反射写，因此编译时不需要 android.jar，javac + d8 即可产出 dex。
 *
 * 输出（stdout，UTF-8，TAB 分隔）：
 *   pkg \t label \t tags
 * tags 为逗号分隔：system / xposed
 * 出错时 stderr 打 ERROR=... 并以非 0 退出。
 */
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.PrintStream;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.List;

public class AppInfo {

    static final int GET_META_DATA = 0x00000080;
    static final int FLAG_SYSTEM = 0x00000001;
    static final int FLAG_UPDATED_SYSTEM_APP = 0x00000080;

    static PrintStream out;

    public static void main(String[] args) {
        try {
            out = new PrintStream(new FileOutputStream(FileDescriptor.out), true, "UTF-8");
        } catch (Throwable t) {
            out = System.out;
        }
        try {
            run();
        } catch (Throwable t) {
            System.err.println("ERROR=" + t.getClass().getName() + ": " + t.getMessage());
            t.printStackTrace(System.err);
            out.flush();
            System.exit(2);
        }
        out.flush();
    }

    static void run() throws Exception {
        Class<?> cAT = Class.forName("android.app.ActivityThread");
        Object ctx = null;
        String mode = "systemMain";

        // 首选：系统 Context，能用框架资源系统解析应用名
        try {
            Object thread = cAT.getMethod("systemMain").invoke(null);
            ctx = cAT.getMethod("getSystemContext").invoke(thread);
        } catch (Throwable t) {
            mode = "no-context";
        }

        Class<?> cPM = Class.forName("android.content.pm.PackageManager");
        Class<?> cAI = Class.forName("android.content.pm.ApplicationInfo");

        List<?> list;
        Object pm = null;

        if (ctx != null) {
            Class<?> cCtx = Class.forName("android.content.Context");
            pm = cCtx.getMethod("getPackageManager").invoke(ctx);
            list = (List<?>) cPM.getMethod("getInstalledPackages", int.class)
                    .invoke(pm, Integer.valueOf(GET_META_DATA));
        } else {
            // 兜底：直接问 IPackageManager。拿得到包名与 metaData（LSPosed 标记），
            // 但拿不到本地化应用名（没有 Context 就没有资源系统）。
            Object ipm = cAT.getMethod("getPackageManager").invoke(null);
            int uid = 0; // 当前（root）用户
            Object slice = ipm.getClass()
                    .getMethod("getInstalledPackages", int.class, int.class)
                    .invoke(ipm, Integer.valueOf(GET_META_DATA), Integer.valueOf(uid));
            list = (List<?>) slice.getClass().getMethod("getList").invoke(slice);
        }

        Method mLabel = null;
        if (pm != null) {
            try {
                mLabel = cPM.getMethod("getApplicationLabel", cAI);
            } catch (Throwable ignored) {
            }
        }

        Class<?> cBundle = Class.forName("android.os.Bundle");
        Method bGetBool = cBundle.getMethod("getBoolean", String.class);
        Method bGetStr = cBundle.getMethod("getString", String.class);

        Field fAppInfo = null;
        Field fPkg = cAI.getField("packageName");
        Field fLabelRes = cAI.getField("labelRes");
        Field fNonLoc = cAI.getField("nonLocalizedLabel");
        Field fFlags = cAI.getField("flags");
        Field fMeta = cAI.getField("metaData");

        int n = 0;
        for (Object pi : list) {
            if (pi == null) {
                continue;
            }
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

            // ---- 应用名 ----
            CharSequence label = null;
            if (mLabel != null) {
                try {
                    label = (CharSequence) mLabel.invoke(pm, ai);
                } catch (Throwable ignored) {
                }
            }
            if (label == null) {
                try {
                    label = (CharSequence) fNonLoc.get(ai);
                } catch (Throwable ignored) {
                }
            }
            if (label == null) {
                int res = fLabelRes.getInt(ai);
                label = (res != 0) ? ("@0x" + Integer.toHexString(res)) : "";
            }

            // ---- 标记 ----
            StringBuilder tags = new StringBuilder();
            int flags = fFlags.getInt(ai);
            if ((flags & (FLAG_SYSTEM | FLAG_UPDATED_SYSTEM_APP)) != 0) {
                tags.append("system");
            }

            Object meta = null;
            try {
                meta = fMeta.get(ai);
            } catch (Throwable ignored) {
            }
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
        }

        out.println("#mode=" + mode + " count=" + n);
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
