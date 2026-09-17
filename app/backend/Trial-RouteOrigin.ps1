# Dot-source only defines the reader; no native calls run until explicitly requested.
# Route Protocol=3 is NetMgmt, not proof of router advertisements. Native Origin=3
# is NlroRouterAdvertisement. Preserve this evidence separately from route equality.
# Microsoft definitions and alignment requirements:
# https://learn.microsoft.com/en-us/windows/win32/api/netioapi/ns-netioapi-mib_ipforward_row2
# https://learn.microsoft.com/en-us/windows/win32/api/netioapi/nf-netioapi-getipforwardtable2
# https://learn.microsoft.com/en-us/windows/win32/api/nldef/ne-nldef-nl_route_origin

function Get-TrialRouteOriginEvidence {
    [CmdletBinding()]
    param()
    try {
        if (-not ('MnaTrial.RouteOriginReader' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Net;
using System.Runtime.InteropServices;
namespace MnaTrial {
    public sealed class RouteOriginEntry {
        public uint InterfaceIndex;
        public string DestinationPrefix;
        public string NextHop;
        public uint Origin;
    }
    public static class RouteOriginReader {
        // AF_INET6 is requested, so the SOCKADDR_INET union is read as sockaddr_in6.
        [StructLayout(LayoutKind.Sequential)]
        private struct Inet6 {
            public ushort Family;
            public ushort Port;
            public uint Flow;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst=16)] public byte[] Address;
            public uint Scope;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct Prefix {
            public Inet6 Address;
            public byte PrefixLength;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct Row {
            public ulong InterfaceLuid;
            public uint InterfaceIndex;
            public Prefix DestinationPrefix;
            public Inet6 NextHop;
            public byte SitePrefixLength;
            public uint ValidLifetime;
            public uint PreferredLifetime;
            public uint Metric;
            public uint Protocol;
            public byte Loopback;
            public byte AutoconfigureAddress;
            public byte Publish;
            public byte Immortal;
            public uint Age;
            public uint Origin;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct Table {
            public uint NumEntries;
            public Row FirstRow;
        }
        [DllImport("iphlpapi.dll", ExactSpelling=true)]
        private static extern uint GetIpForwardTable2(ushort family, out IntPtr table);
        [DllImport("iphlpapi.dll", ExactSpelling=true)]
        private static extern void FreeMibTable(IntPtr memory);

        private static void ValidateLayout() {
            // The project is x64. Never decode native memory with a guessed layout.
            if (IntPtr.Size != 8 || Marshal.SizeOf(typeof(Inet6)) != 28 ||
                Marshal.SizeOf(typeof(Prefix)) != 32 || Marshal.SizeOf(typeof(Row)) != 104 ||
                Marshal.OffsetOf(typeof(Table), "FirstRow").ToInt32() != 8 ||
                Marshal.OffsetOf(typeof(Row), "InterfaceIndex").ToInt32() != 8 ||
                Marshal.OffsetOf(typeof(Row), "DestinationPrefix").ToInt32() != 12 ||
                Marshal.OffsetOf(typeof(Row), "NextHop").ToInt32() != 44 ||
                Marshal.OffsetOf(typeof(Row), "Protocol").ToInt32() != 88 ||
                Marshal.OffsetOf(typeof(Row), "Age").ToInt32() != 96 ||
                Marshal.OffsetOf(typeof(Row), "Origin").ToInt32() != 100)
                throw new InvalidOperationException("Unsupported route table layout.");
        }
        public static RouteOriginEntry[] Read() {
            ValidateLayout();
            IntPtr table = IntPtr.Zero;
            try {
                uint result = GetIpForwardTable2(23, out table);
                if (result != 0) throw new Win32Exception((int)result);
                if (table == IntPtr.Zero) throw new InvalidOperationException("Missing route table.");
                int count = Marshal.ReadInt32(table);
                if (count < 0 || count > 1000000) throw new InvalidOperationException("Invalid route count.");
                int offset = Marshal.OffsetOf(typeof(Table), "FirstRow").ToInt32();
                int stride = Marshal.SizeOf(typeof(Row));
                List<RouteOriginEntry> entries = new List<RouteOriginEntry>(count);
                HashSet<string> keys = new HashSet<string>(StringComparer.Ordinal);
                for (int index = 0; index < count; index++) {
                    Row row = (Row)Marshal.PtrToStructure(IntPtr.Add(table, checked(offset + index * stride)), typeof(Row));
                    if (row.InterfaceIndex == 0 || row.DestinationPrefix.Address.Family != 23 ||
                        row.NextHop.Family != 23 || row.DestinationPrefix.PrefixLength > 128 || row.Origin > 4 ||
                        (row.DestinationPrefix.Address.Scope != 0 && row.DestinationPrefix.Address.Scope != row.InterfaceIndex) ||
                        (row.NextHop.Scope != 0 && row.NextHop.Scope != row.InterfaceIndex))
                        throw new InvalidOperationException("Invalid route identity.");
                    RouteOriginEntry entry = new RouteOriginEntry {
                        InterfaceIndex = row.InterfaceIndex,
                        DestinationPrefix = new IPAddress(row.DestinationPrefix.Address.Address).ToString() + "/" + row.DestinationPrefix.PrefixLength,
                        NextHop = new IPAddress(row.NextHop.Address).ToString(),
                        Origin = row.Origin
                    };
                    // InterfaceIndex carries the link-local scope, matching Get-NetRoute.
                    string key = entry.InterfaceIndex + "|" + entry.DestinationPrefix + "|" + entry.NextHop;
                    if (!keys.Add(key)) throw new InvalidOperationException("Ambiguous route identity.");
                    entries.Add(entry);
                }
                return entries.ToArray();
            } finally {
                if (table != IntPtr.Zero) FreeMibTable(table);
            }
        }
    }
}
'@ -ErrorAction Stop | Out-Null
        }
        $routes=@([MnaTrial.RouteOriginReader]::Read() | ForEach-Object {
            [pscustomobject]@{InterfaceIndex=$_.InterfaceIndex;DestinationPrefix=$_.DestinationPrefix;NextHop=$_.NextHop;Origin=$_.Origin}
        })
        return [pscustomobject]@{Complete=$true;Routes=$routes}
    } catch {
        # Never publish partial evidence, compiler diagnostics, exception paths or messages.
        return [pscustomobject]@{Complete=$false;Routes=@()}
    }
}
