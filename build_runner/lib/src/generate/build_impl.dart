// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:build/build.dart';
import 'package:build/src/builder/build_step_impl.dart';
import 'package:build/src/builder/logging.dart';
import 'package:build_barback/build_barback.dart' show BarbackResolvers;
import 'package:logging/logging.dart';
import 'package:stack_trace/stack_trace.dart';
import 'package:watcher/watcher.dart';

import '../asset/cache.dart';
import '../asset/reader.dart';
import '../asset/writer.dart';
import '../asset_graph/graph.dart';
import '../asset_graph/node.dart';
import '../logging/logging.dart';
import '../package_builder/package_builder.dart';
import '../package_graph/package_graph.dart';
import '../util/constants.dart';
import 'build_definition.dart';
import 'build_result.dart';
import 'exceptions.dart';
import 'fold_frames.dart';
import 'input_set.dart';
import 'options.dart';
import 'performance_tracker.dart';
import 'phase.dart';
import 'terminator.dart';

final _logger = new Logger('Build');

Future<BuildResult> build(List<BuildAction> buildActions,
    {bool deleteFilesByDefault,
    bool writeToCache,
    PackageGraph packageGraph,
    RunnerAssetReader reader,
    RunnerAssetWriter writer,
    Level logLevel,
    onLog(LogRecord record),
    Stream terminateEventStream,
    bool skipBuildScriptCheck}) async {
  var options = new BuildOptions(
      deleteFilesByDefault: deleteFilesByDefault,
      writeToCache: writeToCache,
      packageGraph: packageGraph,
      reader: reader,
      writer: writer,
      logLevel: logLevel,
      onLog: onLog,
      skipBuildScriptCheck: skipBuildScriptCheck);
  var terminator = new Terminator(terminateEventStream);

  var result = await singleBuild(options, buildActions);

  await terminator.cancel();
  await options.logListener.cancel();
  return result;
}

Future<BuildResult> singleBuild(
    BuildOptions options, List<BuildAction> buildActions) async {
  var buildDefinition = await BuildDefinition.load(options, buildActions);
  var result =
      (await BuildImpl.create(buildDefinition, buildActions)).firstBuild;
  await buildDefinition.resourceManager.beforeExit();
  return result;
}

typedef void _OnDelete(AssetId id);

class BuildImpl {
  BuildResult _firstBuild;
  BuildResult get firstBuild => _firstBuild;

  final AssetGraph _assetGraph;
  final List<BuildAction> _buildActions;
  final _OnDelete _onDelete;
  final PackageGraph _packageGraph;
  final CachingAssetReader _reader;
  final _resolvers = const BarbackResolvers();
  final ResourceManager _resourceManager;
  final RunnerAssetWriter _writer;

  BuildImpl._(
      BuildDefinition buildDefinition, this._buildActions, this._onDelete)
      : _packageGraph = buildDefinition.packageGraph,
        _reader = new CachingAssetReader(buildDefinition.reader),
        _writer = buildDefinition.writer,
        _assetGraph = buildDefinition.assetGraph,
        _resourceManager = buildDefinition.resourceManager;

  static Future<BuildImpl> create(
      BuildDefinition buildDefinition, List<BuildAction> buildActions,
      {void onDelete(AssetId id)}) async {
    var build = new BuildImpl._(buildDefinition, buildActions, onDelete);

    await logTimedAsync(
        _logger,
        'Checking for stale files',
        () => build._firstBuildCleanup(buildDefinition.conflictingAssets,
            buildDefinition.deleteFilesByDefault));

    build._firstBuild = await build.run(buildDefinition.updates);
    return build;
  }

  Future<BuildResult> run(Map<AssetId, ChangeType> updates) async {
    var watch = new Stopwatch()..start();
    _lazyPhases.clear();
    if (updates.isNotEmpty) {
      await logTimedAsync(
          _logger, 'Updating asset graph', () => _updateAssetGraph(updates));
    }
    var result = await _safeBuild(_resourceManager);
    await _resourceManager.disposeAll();
    if (result.status == BuildStatus.success) {
      _logger.info('Succeeded after ${watch.elapsedMilliseconds}ms with '
          '${result.outputs.length} outputs\n\n');
    } else {
      if (result.exception is FatalBuildException) {
        // TODO(???) Really bad idea. Should not set exit codes in libraries!
        exitCode = 1;
      }
      _logger.severe('Failed after ${watch.elapsedMilliseconds}ms',
          result.exception, result.stackTrace);
    }
    return result;
  }

  Future<Null> _updateAssetGraph(Map<AssetId, ChangeType> updates) async {
    _reader.invalidate(await _assetGraph.updateAndInvalidate(
        _buildActions, updates, _packageGraph.root.name, _delete, _reader));
  }

  /// Runs a build inside a zone with an error handler and stack chain
  /// capturing.
  Future<BuildResult> _safeBuild(ResourceManager resourceManager) {
    var done = new Completer<BuildResult>();
    Chain.capture(() async {
      // Run a fresh build.
      var result = await logTimedAsync(
          _logger, 'Running build', () => _runPhases(resourceManager));

      // Write out the dependency graph file.
      await logTimedAsync(_logger, 'Caching finalized dependency graph',
          () async {
        await _writer.writeAsString(
            new AssetId(_packageGraph.root.name, assetGraphPath),
            JSON.encode(_assetGraph.serialize()));
      });

      done.complete(result);
    }, onError: (e, Chain chain) {
      final trace = foldInternalFrames(chain.toTrace()).terse;
      done.complete(new BuildResult(BuildStatus.failure, [],
          exception: e, stackTrace: trace));
    });
    return done.future;
  }

  Future<Null> _firstBuildCleanup(
      Set<AssetId> conflictingAssets, bool deleteFilesByDefault) async {
    if (conflictingAssets.isEmpty) return;

    // Skip the prompt if using this option.
    if (deleteFilesByDefault) {
      _logger.info('Deleting ${conflictingAssets.length} declared outputs '
          'which already existed on disk.');
      await Future.wait(conflictingAssets.map(_delete));
      return;
    }

    // Prompt the user to delete files that are declared as outputs.
    _logger.info('Found ${conflictingAssets.length} declared outputs '
        'which already exist on disk. This is likely because the'
        '`$cacheDir` folder was deleted, or you are submitting generated '
        'files to your source repository.');

    // If not in a standard terminal then we just exit, since there is no way
    // for the user to provide a yes/no answer.
    bool runningInPubRunTest() => Platform.script.scheme == 'data';
    if (stdioType(stdin) != StdioType.TERMINAL || runningInPubRunTest()) {
      throw new UnexpectedExistingOutputsException(conflictingAssets);
    }

    // Give a little extra space after the last message, need to make it clear
    // this is a prompt.
    stdout.writeln();
    var done = false;
    while (!done) {
      stdout.write('\nDelete these files (y/n) (or list them (l))?: ');
      var input = stdin.readLineSync();
      switch (input.toLowerCase()) {
        case 'y':
          stdout.writeln('Deleting files...');
          done = true;
          await Future.wait(conflictingAssets.map(_delete));
          break;
        case 'n':
          throw new UnexpectedExistingOutputsException(conflictingAssets);
          break;
        case 'l':
          for (var output in conflictingAssets) {
            stdout.writeln(output);
          }
          break;
        default:
          stdout.writeln('Unrecognized option $input, (y/n/l) expected.');
      }
    }
  }

  /// Runs the actions in [_buildActions] and returns a [Future<BuildResult>]
  /// which completes once all [BuildAction]s are done.
  Future<BuildResult> _runPhases(ResourceManager resourceManager) async {
    var performanceTracker = new BuildPerformanceTracker()..start();
    final outputs = <AssetId>[];
    for (var phase = 0; phase < _buildActions.length; phase++) {
      var action = _buildActions[phase];
      if (action.isOptional) continue;
      await performanceTracker.trackAction(action, () async {
        if (action is PackageBuildAction) {
          outputs.addAll(await _runPackageBuilder(
              phase, action.package, action.builder, resourceManager));
        } else if (action is AssetBuildAction) {
          var inputs =
              await _matchingInputs(action.inputSet, phase, resourceManager);
          outputs.addAll(await _runBuilder(
              phase, action.builder, inputs, resourceManager));
        } else {
          throw new InvalidBuildActionException.unrecognizedType(action);
        }
      });
    }
    await Future.forEach(
        _lazyPhases.values,
        (Future<Iterable<AssetId>> lazyOuts) async =>
            outputs.addAll(await lazyOuts));
    return new BuildResult(BuildStatus.success, outputs,
        performance: performanceTracker..stop());
  }

  /// Gets a list of all inputs matching [inputSet].
  ///
  /// Lazily builds any optional build actions matching [inputSet].
  Future<Set<AssetId>> _matchingInputs(InputSet inputSet, int phaseNumber,
      ResourceManager resourceManager) async {
    var ids = new Set<AssetId>();
    await Future
        .wait(_assetGraph.packageNodes(inputSet.package).map((node) async {
      if (node is SyntheticAssetNode) return;
      if (!inputSet.matches(node.id)) return;
      if (node is GeneratedAssetNode) {
        if (node.phaseNumber >= phaseNumber) return;
        if (node.needsUpdate) {
          await _runLazyPhaseForInput(
              node.phaseNumber, node.primaryInput, resourceManager);
        }
        if (!node.wasOutput) return;
      }
      ids.add(node.id);
    }));
    return ids;
  }

  /// Runs a normal [builder] with [primaryInputs] as inputs and returns only
  /// the outputs that were newly created.
  ///
  /// Does not return outputs that didn't need to be re-ran or were declared
  /// but not output.
  Future<Iterable<AssetId>> _runBuilder(int phaseNumber, Builder builder,
      Iterable<AssetId> primaryInputs, ResourceManager resourceManager) async {
    var outputLists = await Future.wait(primaryInputs.map(
        (input) => _runForInput(phaseNumber, builder, input, resourceManager)));
    return outputLists.fold<List<AssetId>>(
        <AssetId>[], (combined, next) => combined..addAll(next));
  }

  final _lazyPhases = <String, Future<Iterable<AssetId>>>{};

  /// Lazily runs [phaseNumber] with [input] and [resourceManager].
  Future<Iterable<AssetId>> _runLazyPhaseForInput(
      int phaseNumber, AssetId input, ResourceManager resourceManager) {
    return _lazyPhases.putIfAbsent('$phaseNumber|$input', () async {
      // First check if `input` is generated, and whether or not it was
      // actually output. If it wasn't then we just return an empty list here.
      var inputNode = _assetGraph.get(input);
      if (inputNode is GeneratedAssetNode) {
        // Make sure the `inputNode` is up to date, generate run it.
        if (inputNode.needsUpdate) {
          await _runLazyPhaseForInput(
              inputNode.phaseNumber, inputNode.primaryInput, resourceManager);
        }
        if (!inputNode.wasOutput) return <AssetId>[];
      }

      var action = _buildActions[phaseNumber];

      if (action is PackageBuildAction) {
        return _runPackageBuilder(
            phaseNumber, action.package, action.builder, resourceManager);
      } else if (action is AssetBuildAction) {
        return _runForInput(
            phaseNumber, action.builder, input, resourceManager);
      } else {
        throw new InvalidBuildActionException.unrecognizedType(action);
      }
    });
  }

  Future<Iterable<AssetId>> _runForInput(int phaseNumber, Builder builder,
      AssetId input, ResourceManager resourceManager) async {
    var builderOutputs = expectedOutputs(builder, input);

    // Add `builderOutputs` to the primary outputs of the input.
    var inputNode = _assetGraph.get(input);
    assert(inputNode != null,
        'Inputs should be known in the static graph. Missing $input');
    assert(
        inputNode.primaryOutputs.containsAll(builderOutputs),
        'input $input with builder $builder missing primary outputs: \n' +
            'Got ${inputNode.primaryOutputs.join(', ')} which was missing:\n' +
            builderOutputs
                .where((id) => !inputNode.primaryOutputs.contains(id))
                .join(', '));

    if (!_buildShouldRun(builderOutputs)) return <AssetId>[];

    var wrappedReader = new SingleStepReader(
        _reader,
        _assetGraph,
        phaseNumber,
        input.package,
        (phase, input) => _runLazyPhaseForInput(phase, input, resourceManager));
    var wrappedWriter = new AssetWriterSpy(_writer);
    var logger = new Logger('$builder on $input');
    await runBuilder(builder, [input], wrappedReader, wrappedWriter, _resolvers,
        logger: logger, resourceManager: resourceManager);

    // Reset the state for all the `builderOutputs` nodes based on what was
    // read and written.
    await _setOutputsState(builderOutputs, wrappedReader, wrappedWriter);

    return wrappedWriter.assetsWritten;
  }

  /// Runs the [PackageBuilder] [builder] and returns only the outputs
  /// that were newly created.
  ///
  /// Does not return outputs that didn't need to be re-ran or were declared
  /// but not output.
  Future<Iterable<AssetId>> _runPackageBuilder(int phaseNumber, String package,
      PackageBuilder builder, ResourceManager resourceManager) async {
    var builderOutputs = outputIdsForBuilder(builder, package);

    if (!_buildShouldRun(builderOutputs)) return <AssetId>[];

    var wrappedReader = new SingleStepReader(
        _reader,
        _assetGraph,
        phaseNumber,
        package,
        (phase, input) => _runLazyPhaseForInput(phase, input, resourceManager));
    var wrappedWriter = new AssetWriterSpy(_writer);

    var logger = new Logger('$builder on $package');
    var buildStep = new BuildStepImpl(null, builderOutputs, wrappedReader,
        wrappedWriter, _packageGraph.root.name, _resolvers, resourceManager);
    try {
      // Wrapping in `new Future.value` to work around
      // https://github.com/dart-lang/sdk/issues/31237, users might return
      // synchronously and not have any analysis errors today.
      await scopeLogAsync(
          () => new Future.value(builder.build(buildStep)), logger);
    } finally {
      await buildStep.complete();
    }

    // Reset the state for all the `builderOutputs` nodes based on what was
    // read and written.
    await _setOutputsState(builderOutputs, wrappedReader, wrappedWriter);

    return wrappedWriter.assetsWritten;
  }

  /// Checks and returns whether any [outputs] need to be updated.
  bool _buildShouldRun(Iterable<AssetId> outputs) {
    assert(
        outputs.every((o) => _assetGraph.contains(o)),
        'Outputs should be known statically. Missing '
        '${outputs.where((o) => !_assetGraph.contains(o)).toList()}');

    // A build should be ran if any output needs updating
    return outputs.any((output) =>
        (_assetGraph.get(output) as GeneratedAssetNode).needsUpdate);
  }

  /// Sets the state for all [declaredOutputs] of a build step, by:
  ///
  /// - Setting `needsUpdate` to `false` for each output
  /// - Setting `wasOutput` based on `writer.assetsWritten`.
  /// - Setting `globs` on each output based on `reader.globsRan`
  /// - Adding `declaredOutputs` as outputs to all `reader.assetsRead`.
  /// - Setting the `lastKnownDigest` on each output based on the new contents.
  Future<Null> _setOutputsState(Iterable<AssetId> declaredOutputs,
      SingleStepReader reader, AssetWriterSpy writer) async {
    // Reset the state for each output, setting `wasOutput` to false for now
    // (will set to true in the next loop for written assets).
    for (var output in declaredOutputs) {
      (_assetGraph.get(output) as GeneratedAssetNode)
        ..needsUpdate = false
        ..wasOutput = false
        ..lastKnownDigest = null
        ..globs = reader.globsRan.toSet();
    }

    // Mark the actual outputs as output.
    await Future.wait(writer.assetsWritten.map((output) async {
      (_assetGraph.get(output) as GeneratedAssetNode)
        ..wasOutput = true
        ..lastKnownDigest = await _reader.digest(output);
    }));

    // Update the asset graph based on the dependencies discovered.
    for (var dependency in reader.assetsRead) {
      var dependencyNode = _assetGraph.get(dependency);
      assert(dependencyNode != null, 'Asset Graph is missing $dependency');
      // We care about all builderOutputs, not just real outputs. Updates
      // to dependencies may cause a file to be output which wasn't before.
      dependencyNode.outputs.addAll(declaredOutputs);
    }
  }

  Future _delete(AssetId id) {
    _onDelete?.call(id);
    return _writer.delete(id);
  }
}
