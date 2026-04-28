import 'dart:ui';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';

class NavigationService {
  // Thresholds for distance estimation (based on bounding box area as percentage of image)
  static const double _closeThreshold = 0.25; // 25% of frame
  static const double _midThreshold = 0.08;   // 8% of frame
  
  // Horizontal regions
  static const double _leftRegionEnd = 0.35;
  static const double _rightRegionStart = 0.65;

  String analyzeEnvironmentNormalized(List<DetectedObject> objects, Size imageSize) {
    if (objects.isEmpty) {
      return "Clear path, walk straight.";
    }

    // Convert to a list of simplified object info
    final analyzedObjects = objects.map((obj) {
      final rect = obj.boundingBox;
      final normalizedRect = Rect.fromLTRB(
        rect.left / imageSize.width,
        rect.top / imageSize.height,
        rect.right / imageSize.width,
        rect.bottom / imageSize.height,
      );
      
      final centerX = normalizedRect.center.dx;
      final area = normalizedRect.width * normalizedRect.height;
      
      String label = "obstacle";
      if (obj.labels.isNotEmpty) {
        label = obj.labels.first.text.toLowerCase();
      }
      
      return (label: label, centerX: centerX, area: area);
    }).toList();

    // Sort by area (largest/closest first)
    analyzedObjects.sort((a, b) => b.area.compareTo(a.area));

    final closest = analyzedObjects.first;

    // Special handling for critical obstacles like doors or elevators
    if (closest.label.contains('door')) {
      if (closest.area > _closeThreshold) {
        return "Door directly ahead. Move carefully.";
      }
      return "Door detected further ahead.";
    }

    if (closest.label.contains('elevator')) {
      if (closest.centerX < _leftRegionEnd) return "Elevator on your left.";
      if (closest.centerX > _rightRegionStart) return "Elevator on your right.";
      return "Elevator in the center. Walk straight.";
    }
    
    // Distance estimation
    String distanceDesc = "";
    if (closest.area > _closeThreshold) {
      distanceDesc = "very close";
    } else if (closest.area > _midThreshold) {
      distanceDesc = "a few steps away";
    } else {
      distanceDesc = "ahead";
    }

    // Direction guidance
    if (closest.centerX < _leftRegionEnd) {
      // Obstacle is on the left
      if (closest.area > _closeThreshold) {
        return "${closest.label} on your left. Path is clear, continue walking.";
      }
      return "${closest.label} on left.";
    } else if (closest.centerX > _rightRegionStart) {
      // Obstacle is on the right
      if (closest.area > _closeThreshold) {
        return "${closest.label} on your right. Path is clear, continue walking.";
      }
      return "${closest.label} on right.";
    } else {
      // Obstacle is in center
      if (closest.area > _closeThreshold) {
        return "Obstacle directly ahead. Move left or right to avoid.";
      } else if (closest.area > _midThreshold) {
        final moveDir = closest.centerX < 0.5 ? "right" : "left";
        return "${closest.label} $distanceDesc. Move $moveDir.";
      } else {
        return "Clear path, walk straight. ${closest.label} $distanceDesc.";
      }
    }
  }
}
