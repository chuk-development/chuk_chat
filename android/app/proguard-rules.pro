# ProGuard/R8 Rules for chuk.chat
#
# App is open source - NO obfuscation needed
# Only shrinking and optimization enabled

# ============================================
# DISABLE OBFUSCATION (open source app)
# ============================================
-dontobfuscate

# ============================================
# FLUTTER RULES
# ============================================
# Keep Flutter engine
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.embedding.** { *; }

# Keep Dart classes accessed via platform channels
-keepattributes *Annotation*
-keepattributes Signature

# ============================================
# KOTLIN
# ============================================
-keep class kotlin.** { *; }
-keep class kotlin.Metadata { *; }
-dontwarn kotlin.**

# ============================================
# COMMON LIBRARIES
# ============================================
# Gson (if used)
-keepattributes Signature
-keepattributes *Annotation*
-keep class com.google.gson.** { *; }

# OkHttp / Retrofit (if used via plugins)
-dontwarn okhttp3.**
-dontwarn okio.**
-keep class okhttp3.** { *; }
-keep class okio.** { *; }

# ============================================
# CRYPTO / SECURITY
# ============================================
# Keep crypto classes for certificate pinning
-keep class javax.crypto.** { *; }
-keep class java.security.** { *; }

# ============================================
# PLAY CORE (deferred components - not used but referenced by Flutter)
# ============================================
-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
-dontwarn com.google.android.play.core.splitinstall.SplitInstallException
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManager
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManagerFactory
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest$Builder
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest
-dontwarn com.google.android.play.core.splitinstall.SplitInstallSessionState
-dontwarn com.google.android.play.core.splitinstall.SplitInstallStateUpdatedListener
-dontwarn com.google.android.play.core.tasks.OnFailureListener
-dontwarn com.google.android.play.core.tasks.OnSuccessListener
-dontwarn com.google.android.play.core.tasks.Task

# ============================================
# DEBUGGING
# ============================================
# Keep source file names and line numbers for crash reports
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
