import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

val localProperties = Properties().apply {
    val file = rootProject.file("local.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}
fun localProp(key: String): String =
    (localProperties.getProperty(key) ?: "").replace("\\", "\\\\").replace("\"", "\\\"")

android {
    namespace = "app.delore.android"
    compileSdk = 35

    defaultConfig {
        applicationId = "app.delore.android"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        buildConfigField("int", "FREE_LIMIT", "100")
        buildConfigField("boolean", "ANALYTICS_ENABLED", "false")
        buildConfigField("boolean", "ADVANCED_FILTERS", "true")
        buildConfigField("String", "SUPPORT_EMAIL", "\"contact@kandalintsev.com\"")
        buildConfigField("String", "PRIVACY_URL", "\"https://kandalintsev.com/retract/privacy\"")
        buildConfigField("String", "SUPPORT_URL", "\"mailto:contact@kandalintsev.com\"")
        buildConfigField("String", "TERMS_URL", "\"https://kandalintsev.com/retract/terms\"")
        buildConfigField("String", "PRODUCT_ONE_TIME", "\"app.delore.cleanup.single\"")
        buildConfigField("String", "PRODUCT_PRO_MONTHLY", "\"app.delore.pro.monthly\"")
        buildConfigField("String", "PRODUCT_PRO_YEARLY", "\"app.delore.pro.yearly\"")
        buildConfigField("String", "PRODUCT_PRO_MONTHLY_PROMO", "\"app.delore.pro.monthly.promo\"")
        buildConfigField("String", "PRODUCT_PRO_YEARLY_PROMO", "\"app.delore.pro.yearly.promo\"")
        // Optional publisher notify (see workers/notify). Empty = disabled.
        buildConfigField("String", "NOTIFY_URL", "\"${localProp("NOTIFY_URL")}\"")
        buildConfigField("String", "NOTIFY_SECRET", "\"${localProp("NOTIFY_SECRET")}\"")
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
    testOptions {
        unitTests.isIncludeAndroidResources = false
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.navigation:navigation-compose:2.8.5")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation("com.android.billingclient:billing-ktx:7.1.1")
    debugImplementation("androidx.compose.ui:ui-tooling")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
}
