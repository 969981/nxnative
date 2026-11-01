// Synthetic RomFS inputs exercise the production WriteImage method, including its publication boundary.
using System;
using System.IO;
using System.Collections.Generic;
using System.Reflection;
using System.Threading;
using LibHac;
using LibHac.Fs;
using LibHac.Tools.FsSystem;
using LibHac.Tools.FsSystem.RomFs;

static class ExtractImageTests {
    static readonly BindingFlags Flags = BindingFlags.NonPublic | BindingFlags.Static;
    static int active, peak;
    static CountdownEvent overlap = new CountdownEvent(2);
    sealed class Probe : IStorage {
        readonly IStorage source; readonly bool fail, join, crash; int reading;
        public Probe(IStorage source, bool fail, bool join, bool crash) { this.source = source; this.fail = fail; this.join = join; this.crash = crash; }
        public override Result Read(long offset, Span<byte> data) {
            if (data.Length < 65536) return source.Read(offset, data);
            if (Interlocked.Exchange(ref reading, 1) != 0) throw new IOException("shared worker storage");
            int n = Interlocked.Increment(ref active); int old;
            do { old = peak; } while (n > old && Interlocked.CompareExchange(ref peak, n, old) != old);
            try {
                if (join && !overlap.IsSet) {
                    lock (overlap) { if (!overlap.IsSet) overlap.Signal(); }
                    if (!overlap.Wait(3000)) throw new IOException("reads did not overlap");
                }
                if (crash) throw new IOException("read failed");
                if (fail) return ResultFs.NonRealDataVerificationFailed.Value;
                return source.Read(offset, data);
            } finally { Interlocked.Decrement(ref active); Interlocked.Exchange(ref reading, 0); }
        }
        public override Result GetSize(out long size) => source.GetSize(out size);
        public override Result Flush() => Result.Success;
        public override Result Write(long offset, ReadOnlySpan<byte> data) => throw new NotSupportedException();
        public override Result SetSize(long size) => throw new NotSupportedException();
        public override Result OperateRange(Span<byte> output, OperationId op, long offset, long size, ReadOnlySpan<byte> input) => throw new NotSupportedException();
    }
    static int Main(string[] args) {
        string mode = args[0], dst = args[1];
        if (mode == "package") {
            var type = typeof(P).Assembly.GetType("PackageStorage");
            if (type == null) throw new Exception("positional package reader missing");
            var bytes = new byte[262147]; for (int i = 0; i < bytes.Length; i++) bytes[i] = (byte)(i * 17 + 3);
            string input = dst + ".source"; File.WriteAllBytes(input, bytes);
            try {
                using var reader = (IStorage)Activator.CreateInstance(type, input);
                System.Threading.Tasks.Parallel.For(0, 200, i => {
                    int offset = (i * 997) % 180000; var data = new byte[65536]; reader.Read(offset, data).ThrowIfFailure();
                    for (int j = 0; j < data.Length; j++) if (data[j] != (byte)((offset + j) * 17 + 3)) throw new Exception("positional read mismatch");
                });
                reader.GetSize(out long size).ThrowIfFailure(); if (size != bytes.Length) throw new Exception("wrong package size");
                if (!reader.Read(-1, new byte[1]).IsFailure() || !reader.Read(size - 1, new byte[2]).IsFailure()) throw new Exception("invalid read accepted");
                reader.Read(size, Array.Empty<byte>()).ThrowIfFailure();
            } finally { File.Delete(input); }
            return 0;
        }
        bool damaged = mode == "damage" || mode == "allow", allow = mode == "allow", crash = mode == "failure";
        var builder = new RomFsBuilder();
        if (mode != "empty") {
            var bytes = new byte[(12 << 20) + 37];
            for (int i = 0; i < bytes.Length; i++) bytes[i] = (byte)(i * 17 + 3);
            builder.AddFile("/large", new MemoryStorage(bytes).AsFile(OpenMode.Read));
            builder.AddFile("/dir/small", new MemoryStorage(new byte[] { 1, 2, 3 }).AsFile(OpenMode.Read));
            builder.AddFile("/zero", new MemoryStorage(Array.Empty<byte>()).AsFile(OpenMode.Read));
        }
        using var source = builder.Build();
        Func<IntegrityCheckLevel, IStorage> factory = level => new Probe(source, damaged && level == IntegrityCheckLevel.ErrorOnInvalid, mode == "parallel", crash);
        using var initial = factory(IntegrityCheckLevel.ErrorOnInvalid);
        using var fs = new RomFsFileSystem(initial);
        typeof(P).GetField("g_allow", Flags).SetValue(null, allow);
        typeof(P).GetField("g_lenient", Flags).SetValue(null, (Func<LibHac.Fs.Fsa.IFileSystem>)(() => new RomFsFileSystem(factory(IntegrityCheckLevel.IgnoreOnInvalid))));
        var method = typeof(P).GetMethod("WriteImage", Flags);
        try {
            method.Invoke(null, method.GetParameters().Length == 2 ? new object[] { fs, dst } : new object[] { fs, dst, factory });
            if (crash) throw new Exception("read failure was swallowed");
        } catch (TargetInvocationException e) when (crash && e.InnerException != null) {
            Console.WriteLine("expected read failure: " + e.InnerException.GetBaseException().Message);
        }
        var bad = (List<string>)typeof(P).GetField("g_damaged", Flags).GetValue(null);
        if (bad.Count != (damaged ? 1 : 0) || (damaged && bad[0] != "/large")) throw new Exception("wrong damaged files");
        if (mode == "parallel" && peak < 2) throw new Exception("reads did not overlap");
        Console.WriteLine($"peak reads {peak}; damaged {bad.Count}"); return 0;
    }
}
