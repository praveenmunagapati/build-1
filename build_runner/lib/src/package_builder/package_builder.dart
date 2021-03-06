// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:build/build.dart';

abstract class PackageBuilder {
  /// Generates the outputs for a given [BuildStep].
  Future build(BuildStep buildStep);

  /// The relative paths from the package root to all the outputs that will be
  /// generated by this [PackageBuilder].
  Iterable<String> get outputs;
}

/// Converts `builder.outputs` to [AssetId]s under [package].
Iterable<AssetId> outputIdsForBuilder(PackageBuilder builder, String package) =>
    builder.outputs.map((path) => new AssetId(package, path));
