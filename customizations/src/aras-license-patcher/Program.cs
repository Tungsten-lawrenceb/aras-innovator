using System;
using System.IO;
using Mono.Cecil;
using Mono.Cecil.Cil;

class Program
{
    static int Main(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("Usage: AraSrvLicensePatcher <path to Aras.Server.dll>");
            return 1;
        }
        var path = args[0];
        if (!File.Exists(path)) { Console.Error.WriteLine($"Not found: {path}"); return 1; }

        // Backup
        var bak = path + ".pre-license-strip.bak";
        if (!File.Exists(bak)) File.Copy(path, bak);
        Console.WriteLine($"Backup: {bak}");

        // Load with read-only resolver
        var resolverDir = Path.GetDirectoryName(Path.GetFullPath(path));
        var resolver = new DefaultAssemblyResolver();
        resolver.AddSearchDirectory(resolverDir);
        var rp = new ReaderParameters { AssemblyResolver = resolver, ReadWrite = false };

        var asm = AssemblyDefinition.ReadAssembly(path, rp);
        var mod = asm.MainModule;

        var typeName = "Aras.Server.Filters.ExternalAuthenticationLicenseFilterAttribute";
        var t = mod.GetType(typeName);
        if (t == null) { Console.Error.WriteLine($"Type not found: {typeName}"); return 2; }
        Console.WriteLine($"Found type: {t.FullName}");

        int patched = 0;
        foreach (var m in t.Methods)
        {
            if (m.Name == "CheckExternalAuthenticationLicense" || m.Name == "OnActionExecuting")
            {
                Console.WriteLine($"  Patching {m.Name}({string.Join(",", m.Parameters)}) ...");
                // Replace body with a single `ret`. ActionFilterAttribute.OnActionExecuting
                // is itself a no-op by default, so dropping the chain call is safe.
                var il = m.Body.GetILProcessor();
                m.Body.Instructions.Clear();
                m.Body.ExceptionHandlers.Clear();
                m.Body.Variables.Clear();
                il.Append(il.Create(OpCodes.Ret));
                patched++;
            }
        }

        if (patched == 0) { Console.Error.WriteLine("No methods patched"); return 3; }

        // Write to temp then move (avoids issue with locking on Windows)
        var tmpOut = path + ".patched";
        asm.Write(tmpOut);
        asm.Dispose();
        File.Copy(tmpOut, path, overwrite: true);
        File.Delete(tmpOut);

        Console.WriteLine($"Patched {patched} method(s) in {path}");
        return 0;
    }
}
