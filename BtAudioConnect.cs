// Discover Bluetooth audio KS filters and send KSPROPERTY_ONESHOT_RECONNECT / DISCONNECT.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class BtAudioKs
{
    private const uint CLSCTX_ALL = 0x17;
    private static readonly Guid KSPROPSETID_BtAudio = new Guid("7FA4782A-A2FB-4554-A291-B5A11C8D5A7D");
    private const uint KSPROPERTY_ONESHOT_RECONNECT = 0;
    private const uint KSPROPERTY_ONESHOT_DISCONNECT = 1;
    private const uint KSPROPERTY_TYPE_GET = 1;

    private static readonly Guid CLSID_MMDeviceEnumerator = new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E");
    private static readonly Guid IID_IMMDeviceEnumerator = new Guid("A95664D2-9614-4F35-A746-DE8DB63617E6");
    private static readonly Guid IID_IKsControl = new Guid("28F54685-06FD-11D2-B27A-00A0C9223196");

    public static string Connect(string mmDeviceId)
    {
        return OneShot(mmDeviceId, true);
    }

    public static string Disconnect(string mmDeviceId)
    {
        return OneShot(mmDeviceId, false);
    }

    public static string ConnectMany(string[] mmDeviceIds)
    {
        var sb = new StringBuilder();
        int ok = 0;
        foreach (var id in mmDeviceIds)
        {
            string result = OneShot(id, true);
            sb.AppendLine(result);
            if (result.IndexOf("hr=0x00000000", StringComparison.OrdinalIgnoreCase) >= 0)
                ok++;
        }
        sb.AppendLine("okCount=" + ok);
        return sb.ToString();
    }

    private static string OneShot(string mmDeviceId, bool reconnect)
    {
        if (string.IsNullOrWhiteSpace(mmDeviceId))
            return "EMPTY_ID";

        CoInitialize(IntPtr.Zero);
        Guid clsid = CLSID_MMDeviceEnumerator;
        Guid iid = IID_IMMDeviceEnumerator;
        IntPtr pEnum;
        int hr = CoCreateInstance(ref clsid, IntPtr.Zero, CLSCTX_ALL, ref iid, out pEnum);
        if (hr < 0 || pEnum == IntPtr.Zero)
            return "CoCreateInstance hr=0x" + hr.ToString("X8");

        var enumerator = (IMMDeviceEnumerator)Marshal.GetObjectForIUnknown(pEnum);
        Marshal.Release(pEnum);

        try
        {
            IMMDevice device;
            hr = enumerator.GetDevice(mmDeviceId, out device);
            if (hr < 0 || device == null)
                return "GetDevice hr=0x" + hr.ToString("X8") + " id=" + mmDeviceId;

            try
            {
                Guid iidKs = IID_IKsControl;
                object ksObj;
                hr = device.Activate(ref iidKs, CLSCTX_ALL, IntPtr.Zero, out ksObj);
                if (hr < 0 || ksObj == null)
                    return "IKsControl hr=0x" + hr.ToString("X8") + " id=" + mmDeviceId;

                var ks = (IKsControl)ksObj;
                try
                {
                    var prop = new KSPROPERTY
                    {
                        Set = KSPROPSETID_BtAudio,
                        Id = reconnect ? KSPROPERTY_ONESHOT_RECONNECT : KSPROPERTY_ONESHOT_DISCONNECT,
                        Flags = KSPROPERTY_TYPE_GET
                    };
                    uint bytesReturned;
                    hr = ks.KsProperty(ref prop, (uint)Marshal.SizeOf(typeof(KSPROPERTY)), IntPtr.Zero, 0, out bytesReturned);
                    string action = reconnect ? "RECONNECT" : "DISCONNECT";
                    return action + " hr=0x" + hr.ToString("X8") + " id=" + mmDeviceId;
                }
                finally
                {
                    Marshal.ReleaseComObject(ks);
                }
            }
            finally
            {
                Marshal.ReleaseComObject(device);
            }
        }
        finally
        {
            Marshal.ReleaseComObject(enumerator);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KSPROPERTY
    {
        public Guid Set;
        public uint Id;
        public uint Flags;
    }

    [DllImport("ole32.dll")]
    private static extern int CoInitialize(IntPtr pvReserved);

    [DllImport("ole32.dll")]
    private static extern int CoCreateInstance(ref Guid rclsid, IntPtr pUnkOuter, uint dwClsContext, ref Guid riid, out IntPtr ppv);

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, uint dwStateMask, out IntPtr ppDevices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppEndpoint);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string pwstrId, out IMMDevice ppDevice);
        [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr pClient);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr pClient);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, uint dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
        [PreserveSig] int OpenPropertyStore(int stgmAccess, out IntPtr ppProperties);
        [PreserveSig] int GetId(out IntPtr ppstrId);
        [PreserveSig] int GetState(out uint pdwState);
    }

    [ComImport, Guid("28F54685-06FD-11D2-B27A-00A0C9223196"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IKsControl
    {
        [PreserveSig] int KsProperty(ref KSPROPERTY Property, uint PropertyLength, IntPtr PropertyData, uint DataLength, out uint BytesReturned);
        [PreserveSig] int KsMethod(IntPtr Method, uint MethodLength, IntPtr MethodData, uint DataLength, out uint BytesReturned);
        [PreserveSig] int KsEvent(IntPtr Event, uint EventLength, IntPtr EventData, uint DataLength, out uint BytesReturned);
    }
}
