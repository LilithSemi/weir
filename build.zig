const std = @import("std");

const DEFAULT_RAM_BASE: u64 = 0x80000000;

/// Resolve a `-D<name>=0x...` address option, or a default.
fn optAddr(b: *std.Build, name: []const u8, desc: []const u8, default: u64) u64 {
    if (b.option([]const u8, name, desc)) |s| {
        return std.fmt.parseInt(u64, s, 0) catch std.debug.panic("invalid -D{s}: {s}", .{ name, s });
    }
    return default;
}

fn genLd(
    b: *std.Build,
    ld_gen: *std.Build.Step.Compile,
    dtb_lp: ?std.Build.LazyPath,
    kind: []const u8,
    region: ?u64,
) std.Build.LazyPath {
    const run = b.addRunArtifact(ld_gen);
    if (dtb_lp) |lp| run.addFileArg(lp) else run.addArg("");
    run.addArg(kind);
    const out = run.addOutputFileArg("weir.ld");
    if (region) |r| run.addArg(b.fmt("0x{x}", .{r}));
    return out;
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // RISC-V firmware: freestanding, M-mode capable, soft-float (no F/D so we
    // never have to manage the FPU before handing off). medany code model (set
    // per-module below) is required because we link at 0x80000000.
    //
    // We accept only `-Dcpu` (the nixpkgs zig build hook passes -Dcpu=baseline),
    // never `-Dtarget`: the triple is always riscv64 freestanding. The cpu string
    // is parsed by the same stdlib path standardTargetOptions uses, against our
    // fixed triple, then the firmware's required features are pinned on top.
    const mcpu = b.option([]const u8, "cpu", "Target CPU features to add or subtract");
    var target_query = std.Build.parseTargetQuery(.{
        .arch_os_abi = "riscv64-freestanding-none",
        .cpu_features = mcpu,
    }) catch |err| switch (err) {
        // parseTargetQuery already printed the available CPUs/features to stderr.
        error.ParseFailed => std.process.exit(1),
    };
    target_query.cpu_features_add.addFeatureSet(std.Target.riscv.featureSet(&.{ .m, .a, .c }));
    target_query.cpu_features_sub.addFeatureSet(std.Target.riscv.featureSet(&.{ .d, .f }));
    const target = b.resolveTargetQuery(target_query);

    // Let the platform's ACPI/DT description be supplied at build time so Weir
    // can use a provided AML/DTB instead of generating tables purely.
    const aml_path = b.option([]const u8, "aml", "Path to an ACPI DSDT AML blob to embed as the firmware-provided DSDT");
    const dtb_lp = b.option(std.Build.LazyPath, "dtb", "Device tree to embed: SoC params (read at comptime) + runtime override");

    const ld_gen = b.addExecutable(.{
        .name = "fdt-ld",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fdt_ld.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{
                    .name = "dtree",
                    .module = b.dependency("dtree", .{
                        .target = b.graph.host,
                        .optimize = .ReleaseFast,
                    }).module("dtree"),
                },
            },
        }),
    });

    // An external S-mode payload (ELF) Weir loads and jumps to directly.
    const payload_lp = b.option(std.Build.LazyPath, "payload", "Path to an S-mode ELF payload to embed and load");
    const has_payload = payload_lp != null;

    // A real PE32+ EFI application (e.g. Limine's BOOTRISCV64.EFI) to embed and
    // load through the PE/COFF loader instead of the ELF path.
    const pe_app_path = b.option([]const u8, "pe-app", "Path to a real PE32+ EFI application to embed and load via the PE/COFF loader");

    // Read the EFI application off a virtio-blk disk at boot instead of from an
    // embedded blob. Attach the disk to QEMU with -drive/-device virtio-blk.
    const disk_boot = b.option(bool, "disk-boot", "Load the boot PE off a virtio-blk disk instead of an embedded blob") orelse false;

    // Full boot manager: find an ESP, mount FAT, honour BootOrder/Boot#### (or
    // the \EFI\BOOT\BOOTRISCV64.EFI fallback), and boot the referenced EFI app.
    const boot_manager = b.option(bool, "boot-manager", "Boot via the ESP boot manager (GPT + FAT + BootOrder)") orelse false;

    // An initramfs to hand the Linux kernel via the LoadFile2 protocol, so it
    // reaches a real userspace instead of panicking for lack of a root fs.
    const initrd_path = b.option([]const u8, "initrd", "Path to an initramfs (cpio.gz) to embed and serve via LoadFile2");

    const options = b.addOptions();
    options.addOption(bool, "has_aml", aml_path != null);
    options.addOption(bool, "has_dtb", dtb_lp != null);
    options.addOption(bool, "has_payload", has_payload);
    options.addOption(bool, "has_pe_app", pe_app_path != null);
    options.addOption(bool, "disk_boot", disk_boot);
    options.addOption(bool, "boot_manager", boot_manager);
    options.addOption(bool, "has_initrd", initrd_path != null);
    // SRAM base to relocate the payload's DTB into. The S-mode payload parses the
    // DTB through the DRAM dcache path, which is marginal on the creek DDR (the
    // FSBL's single-word reads are solid, but the payload's i+d dcache-load
    // cadence mis-captures a byte and parseMemory sees "no usable memory"). On-chip
    // SRAM never touches the DDR read path, so copying the DTB there makes the
    // payload's read solid. 0 = off (payload gets the DRAM-resident DTB).

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .medium,
    });
    mod.addOptions("build_options", options);
    // conduit: the shared Midstall HAL, and Weir's single Midstall dependency. It
    // backs Weir's peripheral access (UART, virtio-blk, SDHCI, Harbor, CLINT) and
    // its discovery, and re-exports dtree (comptime SoC-param reading in soc.zig)
    // and almanac (ACPI table building in acpi/*) so Weir never pulls those in
    // directly. conduit's build.zig wires its own transitive deps; we consume the
    // pre-built module for our target.
    const conduit_dep = b.dependency("conduit", .{ .target = target, .optimize = optimize });
    const conduit_mod = conduit_dep.module("conduit");
    // Shared SoC-parameters module: reads the embedded DT at comptime. Used by
    // both the firmware and the FSBL, so neither needs -D address options.
    const soc_mod = b.createModule(.{
        .root_source_file = b.path("src/soc.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .medium,
    });
    soc_mod.addImport("conduit", conduit_mod);
    const soc_opts = b.addOptions();
    soc_opts.addOption(bool, "has_dtb", dtb_lp != null);
    soc_mod.addOptions("build_options", soc_opts);
    if (dtb_lp) |lp| soc_mod.addAnonymousImport("soc_dtb", .{ .root_source_file = lp });

    mod.addImport("soc", soc_mod);
    mod.addImport("conduit", conduit_mod);
    if (dtb_lp) |lp| mod.addAnonymousImport("weir_dtb", .{ .root_source_file = lp });
    if (aml_path) |p| mod.addAnonymousImport("weir_aml", .{ .root_source_file = b.path(p) });
    // cwd_relative so an absolute path (e.g. a Nix store EFI binary) also works.
    if (pe_app_path) |p| mod.addAnonymousImport("weir_pe_app", .{ .root_source_file = .{ .cwd_relative = p } });
    if (initrd_path) |p| mod.addAnonymousImport("weir_initrd", .{ .root_source_file = .{ .cwd_relative = p } });

    if (payload_lp) |lp| {
        mod.addAnonymousImport("weir_payload", .{ .root_source_file = lp });
    }

    const exe = b.addExecutable(.{
        .name = "weir",
        .root_module = mod,
    });
    exe.entry = .{ .symbol_name = "_start" };
    exe.setLinkerScript(genLd(b, ld_gen, dtb_lp, "main", null));
    b.installArtifact(exe);

    // Flat image for `-bios`.
    const bin = exe.addObjCopy(.{ .format = .bin });
    const install_bin = b.addInstallBinFile(bin.getOutput(), "weir.bin");
    b.getInstallStep().dependOn(&install_bin.step);

    // `zig build qemu` boots the firmware under QEMU's virt machine.
    const run = b.addSystemCommand(&.{
        "qemu-system-riscv64",
        "-machine",
        "virt",
        "-smp",
        "2",
        "-m",
        "128M",
        "-nographic",
        "-bios",
    });
    run.addFileArg(bin.getOutput());
    if (b.args) |args| run.addArgs(args);
    const qemu_step = b.step("qemu", "Boot Weir under qemu-system-riscv64 -machine virt");
    qemu_step.dependOn(&run.step);

    // First-stage boot loader: a separate tiny image that runs from SRAM/flash
    // at reset, brings up DRAM, and loads the main firmware into it. Hardware
    // addresses come from the SoC device tree (the shared soc module, comptime);
    // only the flash layout policy and link base are options. `zig build fsbl`.
    {
        // The FSBL executes XIP from the flash window and keeps its writable
        // state + stack in the DRAM window; both bases come from the -Ddtb SoC
        // description (creek has no SRAM), resolved by the dtree-backed linker
        // generator below.
        const fsbl_region = optAddr(b, "fsbl-region", "FSBL DRAM scratch window size (stack + bss)", 0x4000);
        // The main-image flash offset + max are no longer build flags: fdt_ld
        // lowers the `river-firmware` DT partition into the _fsbl_main_offset/_max
        // linker symbols, so the layout follows genip's partition map.

        const fsbl_ddr_stress = b.option(bool, "fsbl-ddr-stress", "FSBL runs a post-eye 5A/C0DE per-bit-error map + sustained-read memtest before jumping to main") orelse false;

        const fopts = b.addOptions();
        fopts.addOption(bool, "ddr_stress", fsbl_ddr_stress);
        // The FSBL reads the runtime DDR `training` node out of the embedded DTB at
        // comptime (ddr_train.desc), so it needs to know whether a DTB is present.
        fopts.addOption(bool, "has_dtb", dtb_lp != null);

        const fmod = b.createModule(.{
            .root_source_file = b.path("src/fsbl/start.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .medium,
        });
        fmod.addOptions("fsbl_options", fopts);
        fmod.addImport("soc", soc_mod); // SoC addresses, comptime from the DT
        fmod.addImport("conduit", conduit_mod);
        // The same embedded DTB the soc module reads. ddr_train walks it at comptime
        // for the runtime `training` node.
        if (dtb_lp) |lp| fmod.addAnonymousImport("soc_dtb", .{ .root_source_file = lp });
        // Share the UART driver with the main firmware (the FSBL module is rooted
        // under src/fsbl, so cross-tree files come in as named imports). uart.zig
        // is a thin adapter over conduit's ns16550a, so it needs conduit too.
        const fsbl_uart_mod = b.createModule(.{
            .root_source_file = b.path("src/console/uart.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .medium,
        });
        fsbl_uart_mod.addImport("conduit", conduit_mod);
        fmod.addImport("uart", fsbl_uart_mod);
        // Share the TPM2 command layer (which pulls in the TIS transport) and the
        // handoff record so the FSBL can measure main Weir into the TPM.
        const fsbl_tpm2_mod = b.createModule(.{
            .root_source_file = b.path("src/tpm/tpm2.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .medium,
        });
        fmod.addImport("tpm2", fsbl_tpm2_mod);
        const fsbl_handoff_mod = b.createModule(.{
            .root_source_file = b.path("src/boot_handoff.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .medium,
        });
        fmod.addImport("boot_handoff", fsbl_handoff_mod);

        const fexe = b.addExecutable(.{ .name = "weir-fsbl", .root_module = fmod });
        fexe.entry = .{ .symbol_name = "_start" };
        fexe.setLinkerScript(genLd(b, ld_gen, dtb_lp, "fsbl", fsbl_region));

        const fbin = fexe.addObjCopy(.{ .format = .bin });
        const finstall = b.addInstallBinFile(fbin.getOutput(), "weir-fsbl.bin");

        const fsbl_step = b.step("fsbl", "Build the first-stage boot loader (weir-fsbl.bin)");
        fsbl_step.dependOn(&finstall.step);
    }

    // Host unit tests for the FSBL DDR training DT parser. The parser is pure, so
    // it runs on the host against a fixture DTB passed with -Dtrain-test-dtb. With
    // no fixture the parse test skips and the pure logic tests still run.
    {
        const train_test_dtb = b.option(std.Build.LazyPath, "train-test-dtb", "DTB fixture for the ddr_train parse unit test");

        const topts = b.addOptions();
        topts.addOption(bool, "has_dtb", false); // ddr_train.desc stays null on host
        topts.addOption(bool, "has_test_dtb", train_test_dtb != null);

        const host_conduit = b.dependency("conduit", .{ .target = b.graph.host, .optimize = optimize }).module("conduit");
        const host_uart = b.createModule(.{
            .root_source_file = b.path("src/console/uart.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        });
        host_uart.addImport("conduit", host_conduit);

        const tmod = b.createModule(.{
            .root_source_file = b.path("src/fsbl/ddr_train.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        });
        tmod.addOptions("fsbl_options", topts);
        tmod.addImport("conduit", host_conduit);
        tmod.addImport("uart", host_uart);
        if (train_test_dtb) |lp| tmod.addAnonymousImport("train_test_dtb", .{ .root_source_file = lp });

        const ttest = b.addTest(.{ .root_module = tmod });
        const run_ttest = b.addRunArtifact(ttest);
        const test_step = b.step("test", "Run the FSBL DDR training unit tests");
        test_step.dependOn(&run_ttest.step);
    }
}
