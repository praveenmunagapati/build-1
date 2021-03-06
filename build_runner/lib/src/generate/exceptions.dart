// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:build/build.dart';
import 'package:build_runner/src/generate/phase.dart';

import 'phase.dart';

class ConcurrentBuildException implements Exception {
  const ConcurrentBuildException();

  @override
  String toString() =>
      'ConcurrentBuildException: Only one build may be running at a time.';
}

abstract class FatalBuildException implements Exception {
  const FatalBuildException();
}

class UnexpectedExistingOutputsException extends FatalBuildException {
  final Set<AssetId> conflictingOutputs;

  const UnexpectedExistingOutputsException(this.conflictingOutputs);

  @override
  String toString() => 'UnexpectedExistingOutputsException: Either you opted '
      'not to delete existing files, or you are not running in interactive '
      'mode and did not specify `deleteFilesByDefault` as `true`.\n\n'
      'Found ${conflictingOutputs.length} outputs already on disk:\n\n'
      '${conflictingOutputs.join('\n')}\n';
}

class InvalidBuildActionException extends FatalBuildException {
  final String _reason;

  InvalidBuildActionException.nonRootPackage(BuildAction action, String root)
      : _reason = 'A build action (${action}) is attempting to operate on '
            'package "${action.package}", but the build script is '
            'located in package "$root". It\'s not valid to attempt to '
            'generate files for another package unless "writeToCache: true" '
            'is used.'
            '\n\n'
            'Did you mean to write:\n'
            '  new BuildAction(..., \'$root\')\n'
            '... instead?';

  InvalidBuildActionException.unrecognizedType(BuildAction action)
      : _reason = 'Unrecognized BuildAction type ${action.runtimeType}, only'
            '`AssetBuildAction` (the default) and `PackageBuildAction` are '
            'supported.';

  @override
  String toString() => 'InvalidBuildActionException: $_reason';
}
