package com.fqapp.fqapp;

import android.app.Activity;
import android.content.Intent;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.*;
import io.flutter.plugin.common.*;

public final class CloudLoginPlugin
        implements FlutterPlugin,
                ActivityAware,
                MethodChannel.MethodCallHandler,
                PluginRegistry.ActivityResultListener {
    private MethodChannel channel;
    private ActivityPluginBinding binding;
    private MethodChannel.Result pending;
    private static final int REQUEST = 18742;

    public void onAttachedToEngine(FlutterPluginBinding b) {
        channel = new MethodChannel(b.getBinaryMessenger(), "fqapp/cloud_login");
        channel.setMethodCallHandler(this);
    }

    public void onDetachedFromEngine(FlutterPluginBinding b) {
        channel.setMethodCallHandler(null);
        cancel();
    }

    public void onAttachedToActivity(ActivityPluginBinding b) {
        binding = b;
        b.addActivityResultListener(this);
    }

    public void onReattachedToActivityForConfigChanges(ActivityPluginBinding b) {
        onAttachedToActivity(b);
    }

    public void onDetachedFromActivityForConfigChanges() {
        if (binding != null) binding.removeActivityResultListener(this);
        binding = null;
    }

    public void onDetachedFromActivity() {
        onDetachedFromActivityForConfigChanges();
        cancel();
    }

    private void cancel() {
        if (pending != null) {
            pending.success(null);
            pending = null;
        }
    }

    public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        if (!call.method.equals("login")) {
            result.notImplemented();
            return;
        }
        String provider = call.argument("provider");
        if (binding == null
                || pending != null
                || !java.util.Arrays.asList(
                                "ali", "onedrive", "quark", "tianyi", "mobile139", "weiyun")
                        .contains(provider)) {
            result.error("unavailable", "授权入口暂不可用", null);
            return;
        }
        pending = result;
        Intent intent =
                new Intent(binding.getActivity(), CloudLoginActivity.class)
                        .putExtra("provider", provider);
        binding.getActivity().startActivityForResult(intent, REQUEST);
    }

    public boolean onActivityResult(int request, int code, Intent data) {
        if (request != REQUEST) return false;
        if (pending != null) {
            pending.success(
                    code == Activity.RESULT_OK && data != null
                            ? data.getStringExtra("token")
                            : null);
            pending = null;
        }
        return true;
    }
}
