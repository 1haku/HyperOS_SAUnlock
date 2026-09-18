import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import android.os.IBinder;

public final class SaProbe {
    private static void printError(String label, Throwable error) {
        System.out.println(label + " " + error);
        Throwable cause = error.getCause();
        while (cause != null && cause != error) {
            System.out.println(label + "_CAUSE " + cause);
            error = cause;
            cause = cause.getCause();
        }
    }

    private static void inspect(String className) {
        try {
            Class<?> type = Class.forName(className);
            System.out.println("CLASS " + className);
            for (Method method : type.getDeclaredMethods()) {
                String name = method.getName().toLowerCase();
                if (name.contains("fiveg") || name.contains("sa") || name.contains("n1")) {
                    System.out.println("METHOD " + Modifier.toString(method.getModifiers()) + " " + method);
                }
            }
        } catch (Throwable error) {
            printError("ERROR " + className, error);
        }
    }

    private static Object manager(String className) throws Exception {
        Class<?> type = Class.forName(className);
        return type.getMethod("getDefault").invoke(null);
    }

    private static void read(String className, String methodName, Class<?>[] parameterTypes, Object... args) {
        try {
            Class<?> type = Class.forName(className);
            Object value = type.getMethod(methodName, parameterTypes).invoke(manager(className), args);
            System.out.println("READ " + className + "." + methodName + "=" + value);
        } catch (Throwable error) {
            printError("READ_ERROR " + className + "." + methodName, error);
        }
    }

    private static Object miuiTelephonyService() throws Exception {
        Class<?> serviceManager = Class.forName("android.os.ServiceManager");
        IBinder binder = (IBinder) serviceManager.getMethod("getService", String.class)
                .invoke(null, "miui.radio.extphone");
        Class<?> stub = Class.forName("miui.telephony.IMiuiTelephony$Stub");
        return stub.getMethod("asInterface", IBinder.class).invoke(null, binder);
    }

    private static void readService(String methodName, Class<?>[] parameterTypes, Object... args) {
        try {
            Object service = miuiTelephonyService();
            Object value = service.getClass().getMethod(methodName, parameterTypes).invoke(service, args);
            System.out.println("SERVICE_READ " + methodName + "=" + value);
        } catch (Throwable error) {
            printError("SERVICE_READ_ERROR " + methodName, error);
        }
    }

    private static Object serviceValue(String methodName, Class<?>[] parameterTypes, Object... args)
            throws Exception {
        Object service = miuiTelephonyService();
        return service.getClass().getMethod(methodName, parameterTypes).invoke(service, args);
    }

    private static boolean writeService(String methodName, Class<?>[] parameterTypes, Object... args) {
        try {
            serviceValue(methodName, parameterTypes, args);
            System.out.println("SERVICE_WRITE " + methodName + "=ok");
            return true;
        } catch (Throwable error) {
            printError("SERVICE_WRITE_ERROR " + methodName, error);
            return false;
        }
    }

    private static void state(int slotId) {
        try {
            Class<?>[] slot = new Class<?>[] {int.class};
            Object saEnabled = serviceValue("isUserFiveGSaEnabled", slot, slotId);
            System.out.println("STATE slot=" + slotId);
            System.out.println("STATE isUserFiveGSaEnabled=" + saEnabled);

            Object networkMode = null;
            try {
                networkMode = serviceValue("getFiveGNetworkMode", slot, slotId);
            } catch (Throwable serviceError) {
                try {
                    Class<?> type = Class.forName("miui.telephony.TelephonyManagerEx");
                    networkMode = type.getMethod("getFiveGNetworkMode", slot)
                            .invoke(manager("miui.telephony.TelephonyManagerEx"), slotId);
                } catch (Throwable managerError) {
                    printError("STATE_NETWORK_MODE_WARNING", managerError);
                }
            }
            System.out.println("STATE fiveGNetworkMode=" + networkMode);
        } catch (Throwable error) {
            printError("STATE_ERROR", error);
            System.exit(2);
        }
    }

    public static void main(String[] args) {
        if (args.length == 2 && ("state".equals(args[0]) || "enable-sa".equals(args[0]) || "disable-sa".equals(args[0]))) {
            if (!"0".equals(args[1]) && !"1".equals(args[1])) {
                System.err.println("Slot must be 0 (SIM 1) or 1 (SIM 2).");
                System.exit(2);
                return;
            }
            int slotId = Integer.parseInt(args[1]);
            if ("state".equals(args[0])) {
                state(slotId);
            } else {
                boolean enabled = "enable-sa".equals(args[0]);
                if (!writeService("setUserFiveGSaEnabled", new Class<?>[] {boolean.class, int.class}, enabled, slotId)) {
                    System.exit(2);
                }
                readService("isUserFiveGSaEnabled", new Class<?>[] {int.class}, slotId);
            }
            return;
        }
        // Keep the original slot-0 commands available for older desktop releases.
        if (args.length == 1 && "state".equals(args[0])) {
            state(0);
            return;
        }
        if (args.length == 1 && "enable-sa-slot0".equals(args[0])) {
            if (!writeService("setUserFiveGSaEnabled", new Class<?>[] {boolean.class, int.class}, true, 0)) {
                System.exit(2);
            }
            readService("isUserFiveGSaEnabled", new Class<?>[] {int.class}, 0);
            return;
        }
        if (args.length == 1 && "disable-sa-slot0".equals(args[0])) {
            if (!writeService("setUserFiveGSaEnabled", new Class<?>[] {boolean.class, int.class}, false, 0)) {
                System.exit(2);
            }
            readService("isUserFiveGSaEnabled", new Class<?>[] {int.class}, 0);
            return;
        }
        if (args.length != 0) {
            System.err.println("Usage: SaProbe state|enable-sa|disable-sa 0|1");
            System.exit(2);
            return;
        }
        inspect("miui.telephony.TelephonyManager");
        inspect("miui.telephony.TelephonyManagerEx");
        inspect("com.xiaomi.mirilhook.MiRilHook");
        Class<?>[] none = new Class<?>[0];
        Class<?>[] slot = new Class<?>[] {int.class};
        read("miui.telephony.TelephonyManager", "isUserFiveGSaEnabled", slot, 0);
        read("miui.telephony.TelephonyManager", "isDualSaSupported", none);
        read("miui.telephony.TelephonyManager", "isDualSaEnabled", none);
        read("miui.telephony.TelephonyManagerEx", "isUserFiveGSaEnabled", slot, 0);
        read("miui.telephony.TelephonyManagerEx", "isN1Supported", none);
        read("miui.telephony.TelephonyManagerEx", "getFiveGNetworkMode", slot, 0);
        read("miui.telephony.TelephonyManagerEx", "isFiveGCapable", none);
        read("miui.telephony.TelephonyManagerEx", "isDualSaSupported", none);
        read("miui.telephony.TelephonyManagerEx", "isDualSaEnabled", none);
        readService("isUserFiveGSaEnabled", slot, 0);
        readService("isN1Supported", none);
        readService("getFiveGNetworkMode", slot, 0);
        readService("isFiveGCapable", none);
        readService("isDualSaSupported", none);
        readService("isDualSaEnabled", none);
    }
}
