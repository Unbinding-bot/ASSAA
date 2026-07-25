import '../math3d.dart';

/// A cell in the coarse 3D grid the rubble pile is discretized into.
/// `confidence` is the fused 0-1 score that drives the red/yellow/green
/// color in the map (see localization/fusion.dart).
class Voxel {
  final int ix, iy, iz;
  final Vec3 center;
  double voidScore = 0.0; // from active-mode tomography
  double tdoaScore = 0.0; // from passive knock/scream localization
  double confidence = 0.0; // fused, 0-1

  Voxel({
    required this.ix,
    required this.iy,
    required this.iz,
    required this.center,
  });

  void reset() {
    voidScore = 0.0;
    tdoaScore = 0.0;
    confidence = 0.0;
  }
}

/// The 3D grid the rubble pile is divided into for mapping.
class VoxelGrid {
  final int nx, ny, nz;
  final Vec3 origin; // min corner
  final double cellSize; // meters
  final List<Voxel> cells;

  VoxelGrid({
    required this.nx,
    required this.ny,
    required this.nz,
    required this.origin,
    required this.cellSize,
  }) : cells = [] {
    for (var iz = 0; iz < nz; iz++) {
      for (var iy = 0; iy < ny; iy++) {
        for (var ix = 0; ix < nx; ix++) {
          final center = Vec3(
            origin.x + (ix + 0.5) * cellSize,
            origin.y + (iy + 0.5) * cellSize,
            origin.z + (iz + 0.5) * cellSize,
          );
          cells.add(Voxel(ix: ix, iy: iy, iz: iz, center: center));
        }
      }
    }
  }

  void resetAll() {
    for (final c in cells) {
      c.reset();
    }
  }
}