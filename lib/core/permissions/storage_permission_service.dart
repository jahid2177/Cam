import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

/// Result of asking for access to images that live outside OpenScan's
/// private application directory.
///
/// Android 13+ exposes this as the Photos permission. Android 12L and older
/// use the legacy Storage permission. The service tries the modern permission
/// first and falls back to legacy storage so one code path works across the
/// Android versions supported by the project.
enum StoragePermissionResult {
  granted,
  limited,
  denied,
  permanentlyDenied,
}

class StoragePermissionService {
  StoragePermissionService._();

  /// Requests the permission needed before importing images from the user's
  /// media library.
  ///
  /// On modern Android, [Permission.photos] maps to media-image access. On
  /// older Android releases that permission is unavailable, so the method
  /// falls back to [Permission.storage]. iOS is also handled by
  /// [Permission.photos]. Other platforms are treated as granted because
  /// this service is only used by the Android/iOS gallery flow.
  static Future<StoragePermissionResult> requestGalleryAccess() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return StoragePermissionResult.granted;
    }

    final photoStatus = await Permission.photos.status;
    final mappedPhotoStatus = _mapStatus(photoStatus);
    if (mappedPhotoStatus == StoragePermissionResult.granted ||
        mappedPhotoStatus == StoragePermissionResult.limited) {
      return mappedPhotoStatus;
    }

    final requestedPhotos = await Permission.photos.request();
    final mappedRequestedPhotos = _mapStatus(requestedPhotos);
    if (mappedRequestedPhotos == StoragePermissionResult.granted ||
        mappedRequestedPhotos == StoragePermissionResult.limited) {
      return mappedRequestedPhotos;
    }

    // On iOS there is no Android-style legacy storage permission to fall
    // back to. Preserve the Photos result there.
    if (Platform.isIOS) {
      return mappedRequestedPhotos;
    }

    // Android 12L and below use READ_EXTERNAL_STORAGE through
    // Permission.storage. Android 13+ may report this permission as denied;
    // on those versions Permission.photos above is the authoritative result.
    final storageStatus = await Permission.storage.status;
    final mappedStorageStatus = _mapStatus(storageStatus);
    if (mappedStorageStatus == StoragePermissionResult.granted) {
      return mappedStorageStatus;
    }

    final requestedStorage = await Permission.storage.request();
    final mappedRequestedStorage = _mapStatus(requestedStorage);
    if (mappedRequestedStorage == StoragePermissionResult.granted) {
      return mappedRequestedStorage;
    }

    if (requestedPhotos.isPermanentlyDenied ||
        requestedPhotos.isRestricted ||
        requestedStorage.isPermanentlyDenied ||
        requestedStorage.isRestricted) {
      return StoragePermissionResult.permanentlyDenied;
    }

    return StoragePermissionResult.denied;
  }

  /// Opens this application's system settings page so a user can restore a
  /// permission that Android/iOS no longer allows the app to request again.
  static Future<bool> openSettings() => openAppSettings();

  static StoragePermissionResult _mapStatus(PermissionStatus status) {
    if (status.isGranted) return StoragePermissionResult.granted;
    if (status.isLimited) return StoragePermissionResult.limited;
    if (status.isPermanentlyDenied || status.isRestricted) {
      return StoragePermissionResult.permanentlyDenied;
    }
    return StoragePermissionResult.denied;
  }
}
