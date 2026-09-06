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
    dtb_path: ?std.Build.LazyPath,
    kind: []const u8,
    region: ?u64,
) std.Build.LazyPath {
    const run = b.addRunArtifact(ld_gen);
    if (dtb_path) |lp| run.addFileArg(lp) else run.addArg("");
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
    const aml_path = b.option(std.Build.LazyPath, "aml", "Path to an ACPI DSDT AML blob to embed as the firmware-provided DSDT");
    const dtb_path = b.option(std.Build.LazyPath, "dtb", "Device tree to embed: SoC params (read at comptime) + runtime override");

    // Host-side device-tree reader, shared by every build-time tool that reads
    // the SoC tree (the linker-script generator and the flash-image assembler).
    const dtree_host = b.dependency("dtree", .{
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    }).module("dtree");

    // The DT base parser both host tools share, so the FSBL link offsets and the
    // offsets the flash image places the FSBL/firmware at read from one source.
    const fdt_bases_mod = b.createModule(.{
        .root_source_file = b.path("tools/fdt_bases.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "dtree", .module = dtree_host },
        },
    });

    const ld_gen = b.addExecutable(.{
        .name = "fdt2ld",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fdt2ld.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "dtree", .module = dtree_host },
                .{ .name = "fdt_bases", .module = fdt_bases_mod },
            },
        }),
    });

    // An external S-mode payload (ELF) Weir loads and jumps to directly.
    const payload_path = b.option(std.Build.LazyPath, "payload", "Path to an S-mode ELF payload to embed and load");
    const has_payload = payload_path != null;

    // A real PE32+ EFI application (e.g. Limine's BOOTRISCV64.EFI) to embed and
    // load through the PE/COFF loader instead of the ELF path.
    const pe_app_path = b.option(std.Build.LazyPath, "pe-app", "Path to a real PE32+ EFI application to embed and load via the PE/COFF loader");

    // Read the EFI application off a disk at boot instead of from an
    // embedded blob.
    const disk_boot = b.option(bool, "disk-boot", "Load the boot PE as a bare image at sector 0 of any device-tree disk, instead of an embedded blob") orelse (payload_path == null);

    // Full boot manager: find an ESP, mount FAT, honour BootOrder/Boot#### (or
    // the \EFI\BOOT\BOOTRISCV64.EFI fallback), and boot the referenced EFI app.
    const boot_manager = b.option(bool, "boot-manager", "Boot via the ESP boot manager (GPT + FAT + BootOrder)") orelse disk_boot;

    // An initramfs to hand the Linux kernel via the LoadFile2 protocol, so it
    // reaches a real userspace instead of panicking for lack of a root fs.
    const initrd_path = b.option(std.Build.LazyPath, "initrd", "Path to an initramfs (cpio.gz) to embed and serve via LoadFile2");

    const options = b.addOptions();
    options.addOption(bool, "has_aml", aml_path != null);
    options.addOption(bool, "has_dtb", dtb_path != null);
    options.addOption(bool, "has_payload", has_payload);
    options.addOption(bool, "has_pe_app", pe_app_path != null);
    options.addOption(bool, "disk_boot", disk_boot);
    options.addOption(bool, "boot_manager", boot_manager);
    options.addOption(bool, "has_initrd", initrd_path != null);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .medium,
    });
    mod.addOptions("build_options", options);

    const conduit_dep = b.dependency("conduit", .{
        .target = target,
        .optimize = optimize,
    });
    const conduit_mod = conduit_dep.module("conduit");

    const soc_mod = b.createModule(.{
        .root_source_file = b.path("src/soc.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .medium,
    });
    soc_mod.addImport("conduit", conduit_mod);

    // One options module carrying `has_dtb`, shared by the soc module (as
    // `build_options`) and the FSBL (as `fsbl_options`). It is the same flag, so
    // sharing the module avoids two identical-content option files colliding when
    // the FSBL graph pulls in soc.
    const soc_opts = b.addOptions();
    soc_opts.addOption(bool, "has_dtb", dtb_path != null);
    const soc_opts_mod = soc_opts.createModule();
    soc_mod.addImport("build_options", soc_opts_mod);
    if (dtb_path) |p| soc_mod.addAnonymousImport("soc_dtb", .{ .root_source_file = p });

    mod.addImport("soc", soc_mod);
    mod.addImport("conduit", conduit_mod);
    if (dtb_path) |p| mod.addAnonymousImport("weir_dtb", .{ .root_source_file = p });
    if (aml_path) |p| mod.addAnonymousImport("weir_aml", .{ .root_source_file = p });
    // cwd_relative so an absolute path (e.g. a Nix store EFI binary) also works.
    if (pe_app_path) |p| mod.addAnonymousImport("weir_pe_app", .{ .root_source_file = p });
    if (initrd_path) |p| mod.addAnonymousImport("weir_initrd", .{ .root_source_file = p });

    if (payload_path) |lp| {
        mod.addAnonymousImport("weir_payload", .{ .root_source_file = lp });
    }

    const exe = b.addExecutable(.{
        .name = "weir-firmware",
        .root_module = mod,
    });
    exe.entry = .{ .symbol_name = "_start" };
    exe.setLinkerScript(genLd(b, ld_gen, dtb_path, "main", null));

    // The linked ELF (for debugging and inspection).
    const install_elf = b.addInstallBinFile(exe.getEmittedBin(), "weir-firmware.elf");
    b.getInstallStep().dependOn(&install_elf.step);

    // Flat image for `-bios`.
    const bin = exe.addObjCopy(.{ .format = .bin });
    const install_bin = b.addInstallBinFile(bin.getOutput(), "weir-firmware.bin");
    b.getInstallStep().dependOn(&install_bin.step);

    // Packed image with the WEIR header the FSBL reads, ready to flash to the
    // `river-firmware` partition.
    const packer = b.addExecutable(.{
        .name = "pack-fw",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/pack-fw.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
        }),
    });
    const pack = b.addRunArtifact(packer);
    pack.addFileArg(bin.getOutput());
    const packed_bin = pack.addOutputFileArg("weir-firmware-packed.bin");
    const install_packed = b.addInstallBinFile(packed_bin, "weir-firmware-packed.bin");
    b.getInstallStep().dependOn(&install_packed.step);

    // `zig build test` runs the unit tests of the platform-independent parts.
    // They build for the host, so only modules with no hardware or SoC imports
    // belong here. src/acpi/madt.zig is one: it lays out MADT bytes and nothing
    // else, so its tests pin the table an OS reads.
    const test_step = b.step("test", "Run the unit tests");
    const madt_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/acpi/madt.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(madt_tests).step);

    // src/soc.zig resolves every SoC parameter at comptime from the embedded
    // device tree. Built for the host against the same tree and the same
    // conduit, its tests exercise the exact comptime path the firmware uses, so
    // a tree that stops declaring something fails `zig build test` and not a
    // board. It needs a host build of conduit, because the firmware one is
    // riscv64.
    const conduit_host = b.dependency("conduit", .{
        .target = b.graph.host,
        .optimize = optimize,
    }).module("conduit");
    const soc_test_mod = b.createModule(.{
        .root_source_file = b.path("src/soc.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    soc_test_mod.addImport("conduit", conduit_host);
    soc_test_mod.addImport("build_options", soc_opts_mod);
    if (dtb_path) |p| soc_test_mod.addAnonymousImport("soc_dtb", .{ .root_source_file = p });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = soc_test_mod })).step);

    // `zig build qemu` boots the firmware under QEMU's virt machine.
    const run = b.addSystemCommand(&.{
        "qemu-system-riscv64",
        "-machine",
        "virt",
        "-smp",
        "1",
        "-m",
        "2G",
        "-nographic",
        // Weir's virtio driver speaks the modern (non-legacy) interface only.
        "-global",
        "virtio-mmio.force-legacy=false",
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
        const fmod = b.createModule(.{
            .root_source_file = b.path("src/fsbl/start.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .medium,
        });
        fmod.addImport("fsbl_options", soc_opts_mod);
        fmod.addImport("soc", soc_mod); // SoC addresses, comptime from the DT
        fmod.addImport("conduit", conduit_mod);
        // The same embedded DTB the soc module reads. ddr_train walks it at comptime
        // for the runtime `training` node.
        if (dtb_path) |p| fmod.addAnonymousImport("soc_dtb", .{ .root_source_file = p });
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
        fexe.setLinkerScript(genLd(b, ld_gen, dtb_path, "fsbl", null));

        const fbin = fexe.addObjCopy(.{ .format = .bin });
        const finstall = b.addInstallBinFile(fbin.getOutput(), "weir-fsbl.bin");

        b.getInstallStep().dependOn(&finstall.step);

        // `weir.img`: the single flash-and-go image. It lays the FSBL (XIP) and
        // the packed firmware into one flash-sized image at the `river-fsbl` and
        // `river-firmware` partition offsets. mkflash reads those offsets and the
        // flash size from the same DT the FSBL links against (tools/fdt_bases.zig),
        // so the image and the linker script cannot drift. Installed by default.
        const flash_packer = b.addExecutable(.{
            .name = "mkflash",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/mkflash.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseFast,
                .imports = &.{
                    .{ .name = "dtree", .module = dtree_host },
                    .{ .name = "fdt_bases", .module = fdt_bases_mod },
                },
            }),
        });

        const make_img = b.addRunArtifact(flash_packer);
        if (dtb_path) |lp| make_img.addFileArg(lp) else make_img.addArg("");
        make_img.addFileArg(fbin.getOutput());
        make_img.addFileArg(packed_bin);
        const weir_img = make_img.addOutputFileArg("weir.img");
        const install_img = b.addInstallBinFile(weir_img, "weir.img");
        b.getInstallStep().dependOn(&install_img.step);
    }
}
