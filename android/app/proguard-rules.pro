# JNI (game_texture.so): JNI_OnLoad looks up notifyFrame; native methods use standard JNI names.
-keepclassmembers class com.example.gba_emulator.GameTexturePlugin {
    public static void notifyFrame();
}

-keepclasseswithmembernames class com.example.gba_emulator.GameTexturePlugin {
    native <methods>;
}
