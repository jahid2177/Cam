# ============================================================
# DocScan - R8 / ProGuard Rules
# ============================================================

# ------------------------------------------------------------
# Flutter
# ------------------------------------------------------------

-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugins.** { *; }

-dontwarn io.flutter.**

# ------------------------------------------------------------
# Flutter Play Store Deferred Components
#
# Flutter contains optional deferred-component integration.
# DocScan does not use Play Store dynamic feature delivery,
# therefore these optional Play Core classes may be absent.
# ------------------------------------------------------------

-dontwarn com.google.android.play.core.**
-dontwarn com.google.android.play.core.splitcompat.**
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**

# ------------------------------------------------------------
# Google ML Kit
# ------------------------------------------------------------

-keep class com.google.mlkit.** { *; }

-dontwarn com.google.mlkit.**

# Optional ML Kit text-recognition language modules.
# These modules are not required for the standard Latin
# text recognizer used by DocScan.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# ------------------------------------------------------------
# Google Play Services
# ------------------------------------------------------------

-keep class com.google.android.gms.tasks.** { *; }
-dontwarn com.google.android.gms.tasks.**

# ------------------------------------------------------------
# AndroidX
# ------------------------------------------------------------

-dontwarn androidx.**

# ------------------------------------------------------------
# Kotlin
# ------------------------------------------------------------

-dontwarn kotlin.**
-dontwarn kotlinx.**

# ------------------------------------------------------------
# Keep metadata required by plugins/libraries
# ------------------------------------------------------------

-keepattributes Signature
-keepattributes InnerClasses
-keepattributes EnclosingMethod
-keepattributes *Annotation*
-keepattributes RuntimeVisibleAnnotations
-keepattributes RuntimeInvisibleAnnotations
-keepattributes AnnotationDefault
