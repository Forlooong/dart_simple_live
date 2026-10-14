// These injection points are intentionally tied to native_toolchain_rust 1.0.4.
// ignore_for_file: implementation_imports, invalid_use_of_internal_member
import 'dart:io';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';
import 'package:native_toolchain_rust/src/build_environment.dart';
import 'package:native_toolchain_rust/src/build_runner.dart';
import 'package:native_toolchain_rust/src/crate_info_validator.dart';
import 'package:native_toolchain_rust/src/crate_resolver.dart';
import 'package:native_toolchain_rust/src/dependency_discoverer.dart';
import 'package:native_toolchain_rust/src/process_runner.dart';
import 'package:native_toolchain_rust/src/toml_parsing.dart';
import 'package:path/path.dart' as p;

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final environment = <String, String>{};
    if (code.targetOS == OS.android) {
      final triple = switch (code.targetArchitecture) {
        Architecture.arm => 'armv7-linux-androideabi',
        Architecture.arm64 => 'aarch64-linux-android',
        Architecture.x64 => 'x86_64-linux-android',
        _ => throw UnsupportedError('Unsupported Android architecture'),
      };
      final ndkTriple = triple.replaceFirst('armv7-', 'armv7a-');
      final bin = p.dirname(code.cCompiler!.compiler.toFilePath());
      final suffix = Platform.isWindows ? '.cmd' : '';
      final cc = p.join(bin, '${ndkTriple}24-clang$suffix');
      final cxx = p.join(bin, '${ndkTriple}24-clang++$suffix');
      if (!File(cc).existsSync()) {
        throw StateError('NDK API 24 compiler missing');
      }
      final key = triple.replaceAll('-', '_');
      environment.addAll({
        'CC_$key': cc,
        'CXX_$key': cxx,
        'CARGO_TARGET_${key.toUpperCase()}_LINKER': cc,
        'CARGO_TARGET_${key.toUpperCase()}_RUSTFLAGS':
            '-C link-arg=-Wl,-z,max-page-size=16384',
      });
    }
    if (code.targetOS == OS.iOS) {
      environment['IPHONEOS_DEPLOYMENT_TARGET'] = '14.0';
    }
    final logger = Logger.detached('danmaku-native')..level = Level.WARNING;
    logger.onRecord.listen((record) => stderr.writeln(record.message));
    final rustConfig = RustBuilder(
      assetName: 'src/bindings.dart',
      cratePath: 'rust',
      extraCargoBuildArgs: const ['--locked'],
      extraCargoEnvironmentVariables: environment,
    );
    // 1.0.4 splits Cargo dep-info on spaces. Register our locked source inputs
    // directly instead, preserving Windows drive letters and spaces in paths.
    final root = Directory.fromUri(input.packageRoot.resolve('rust/'));
    final sources = <Uri>[];
    void track(Directory directory) {
      for (final entry in directory.listSync(followLinks: false)) {
        if (entry is Directory) {
          if (!['target', '.git'].contains(p.basename(entry.path))) {
            track(entry);
          }
        } else if (entry is File) {
          sources.add(entry.uri);
        }
      }
    }

    track(root);
    final tomlFactory = TomlDocumentWrapperFactory(logger);
    await RustBuildRunner(
      config: rustConfig,
      logger: logger,
      crateDirectoryResolver: const CrateDirectoryResolver(),
      processRunner: _LocalToolchainRunner(logger, localToolchainHomes()),
      buildEnvironmentFactory: const BuildEnvironmentFactory(),
      crateInfoValidator: CrateInfoValidator(
        toolchainTomlParser: ToolchainTomlParser(logger, tomlFactory),
        cargoManifestParser: CargoManifestParser(logger, tomlFactory),
      ),
      dependencyDiscoverer: _SourceDependencies(logger, sources),
    ).run(input: input, output: output, assetRouting: const [ToAppBundle()]);
  });
}

/// Dart build hooks filter their inherited environment, including CARGO_HOME
/// and RUSTUP_HOME. Recover a colocated project toolchain from PATH, which the
/// hook runner preserves. Ordinary CI installations have no sibling rustup
/// directory and continue using their standard homes.
Map<String, String> localToolchainHomes() {
  final inherited = Platform.environment;
  if (inherited.containsKey('CARGO_HOME') ||
      inherited.containsKey('RUSTUP_HOME')) {
    return {};
  }
  for (var entry in (inherited['PATH'] ?? '').split(
    Platform.isWindows ? ';' : ':',
  )) {
    entry = entry.replaceAll('"', '').trim();
    if (entry.isEmpty || p.basename(entry).toLowerCase() != 'bin') continue;
    final cargoHome = p.dirname(p.normalize(entry));
    final rustupHome = p.join(p.dirname(cargoHome), 'rustup');
    final executable = p.join(
      entry,
      Platform.isWindows ? 'rustup.exe' : 'rustup',
    );
    if (File(executable).existsSync() && Directory(rustupHome).existsSync()) {
      return {'CARGO_HOME': cargoHome, 'RUSTUP_HOME': rustupHome};
    }
  }
  return {};
}

class _LocalToolchainRunner implements ProcessRunner {
  _LocalToolchainRunner(this.logger, this.homes);
  @override
  final Logger logger;
  final Map<String, String> homes;

  @override
  Future<String> invoke(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    // Apply to toolchain discovery as well as cargo build. extraCargoEnvironment
    // alone misses the initial `rustup show active-toolchain` invocation.
    return ProcessRunner(logger).invoke(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: {...homes, ...?environment},
    );
  }
}

class _SourceDependencies implements DependencyDiscoverer {
  _SourceDependencies(this.logger, this.sources);
  @override
  final Logger logger;
  final List<Uri> sources;
  @override
  Iterable<Uri> discover(String dependencyFilePath) => sources;
}
