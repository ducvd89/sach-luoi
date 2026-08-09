plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.sachnoi.sach_noi"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.sachnoi.sach_noi"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Chỉ arm64. Thư viện native của engine VieNeu chỉ dựng cho kiến trúc
        // này, nên bản 32-bit hay x86 sẽ cài được mà không đọc được. Chặn ở đây
        // còn bỏ luôn được ~50 MB thư viện thừa mà sherpa-onnx mang theo.
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    // abiFilters không loại được thư viện đến từ các gói AAR (sherpa-onnx,
    // media_kit), phải chặn thẳng ở bước đóng gói.
    //
    // ĐỪNG chép libonnxruntime.so vào jniLibs/. ONNX Runtime đến từ gói
    // sherpa_onnx và cả hai engine dùng chung nó (VieNeu nạp lúc chạy qua
    // load-dynamic nên không kén phiên bản).
    //
    // Thêm bản thứ hai là hỏng engine Giọng nhẹ mà build vẫn xanh:
    // libsherpa-onnx-c-api.so nhập symbol CÓ GẮN VERSION
    // (OrtGetApiBase@VERS_1.27.0), hai file lại cùng SONAME libonnxruntime.so
    // nên chỉ một bản sống sót — và bản trong jniLibs/ thắng. Sai version node
    // là dlopen hỏng, engine im lặng không chạy. Windows không dính vì PE
    // không có symbol versioning, nên lỗi chỉ lộ ra trên Android.
    packaging {
        jniLibs {
            excludes += setOf("**/armeabi-v7a/**", "**/x86/**", "**/x86_64/**")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
