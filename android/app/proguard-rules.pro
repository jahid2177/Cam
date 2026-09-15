# ============================================================
# DocScan - ProGuard / R8 Rules
# ============================================================

# Flutter
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# ============================================================
# Google ML Kit
# ============================================================

# Keep ML Kit classes
-keep class com.google.mlkit.** { *; }
-dontwarn com.google.mlkit.**

# Keep Google Play Services Tasks
-keep class com.google.android.gms.tasks.** { *; }
-dontwarn com.google.android.gms.tasks.**

# ============================================================
# ML Kit Text Recognition
#
# google_mlkit_text_recognition references optional language
# recognizers even when those language modules aren't included.
# R8 must not fail because those optional classes are absent.
# ============================================================

-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# ============================================================
# ML Kit Barcode Scanning
# ============================================================

-keep class com.google.mlkit.vision.barcode.** { *; }
-dontwarn com.google.mlkit.vision.barcode.**

# ============================================================
# AndroidX
# ============================================================

-dontwarn androidx.**
-keepattributes *Annotation*

# ============================================================
# Kotlin
# ============================================================

-dontwarn kotlin.**
-dontwarn kotlinx.**

# ============================================================
# Keep useful metadata
# ============================================================

-keepattributes Signature
-keepattributes InnerClasses
-keepattributes EnclosingMethod
-keepattributes RuntimeVisibleAnnotations
-keepattributes RuntimeInvisibleAnnotations
-keepattributes AnnotationDefault
