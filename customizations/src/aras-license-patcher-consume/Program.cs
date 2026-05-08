using System;
using System.IO;
using System.Linq;
using Mono.Cecil;
using Mono.Cecil.Cil;

class Program
{
    static int Main(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("Usage: PatchConsumeLicense <path to Aras.Server.Core.dll>");
            return 1;
        }
        var path = args[0];
        if (!File.Exists(path)) { Console.Error.WriteLine("Not found: " + path); return 1; }

        var bak = path + ".pre-consume-license-strip.bak";
        if (!File.Exists(bak)) File.Copy(path, bak);
        Console.WriteLine("Backup: " + bak);

        var resolverDir = Path.GetDirectoryName(Path.GetFullPath(path));
        var resolver = new DefaultAssemblyResolver();
        resolver.AddSearchDirectory(resolverDir);
        var rp = new ReaderParameters { AssemblyResolver = resolver, ReadWrite = false };

        var asm = AssemblyDefinition.ReadAssembly(path, rp);
        var mod = asm.MainModule;

        var typeName = "Aras.Server.Licensing.LicenseManager";
        var t = mod.GetType(typeName);
        if (t == null) { Console.Error.WriteLine("Type not found: " + typeName); return 2; }

        int patched = 0;
        foreach (var m in t.Methods)
        {
            // Target: public string ConsumeLicense(string feature)
            if (m.Name != "ConsumeLicense") continue;
            if (m.Parameters.Count != 1) continue;
            if (m.Parameters[0].ParameterType.FullName != "System.String") continue;
            if (m.ReturnType.FullName != "System.String") continue;

            Console.WriteLine("Patching " + t.FullName + "::" + m.Name + "(string)");

            var il = m.Body.GetILProcessor();
            m.Body.Instructions.Clear();
            m.Body.ExceptionHandlers.Clear();
            m.Body.Variables.Clear();
            il.Append(il.Create(OpCodes.Ldstr, "RC_BYPASS_LICENSE"));
            il.Append(il.Create(OpCodes.Ret));
            patched++;
        }

        if (patched == 0)
        {
            Console.Error.WriteLine("No matching ConsumeLicense methods patched.");
            return 3;
        }

        var tmpOut = path + ".patched";
        asm.Write(tmpOut);
        asm.Dispose();
        File.Copy(tmpOut, path, overwrite: true);
        File.Delete(tmpOut);
        Console.WriteLine("Patched " + patched + " method(s) in " + path);
        return 0;
    }
}
