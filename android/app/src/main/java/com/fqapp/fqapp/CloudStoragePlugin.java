package com.fqapp.fqapp;

import android.os.Handler;
import android.os.Looper;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.*;

import org.json.*;

import java.util.*;
import java.util.concurrent.*;

/** Native protocol sessions contain no saved credentials and no reader data. */
public final class CloudStoragePlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
    private MethodChannel channel;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final Map<String, CloudDrive> sessions = new ConcurrentHashMap<>();

    public void onAttachedToEngine(FlutterPluginBinding binding) {
        channel = new MethodChannel(binding.getBinaryMessenger(), "fqapp/cloud_storage");
        channel.setMethodCallHandler(this);
    }

    public void onDetachedFromEngine(FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
        worker.shutdownNow();
        sessions.clear();
    }

    public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        worker.execute(
                () -> {
                    try {
                        Object value;
                        if (call.method.equals("open")) {
                            String provider = call.argument("provider"),
                                    credential = call.argument("password");
                            CloudDrive drive;
                            if ("quark".equals(provider)) drive = new QuarkCloudDrive(credential);
                            else if ("tianyi".equals(provider))
                                drive = new TianyiCloudDrive(credential);
                            else if ("mobile139".equals(provider))
                                drive = new MobileCloudDrive(credential);
                            else throw new IllegalArgumentException("Unsupported cloud provider");
                            drive.authenticate(Boolean.TRUE.equals(call.argument("forceRefresh")));
                            String id = UUID.randomUUID().toString();
                            sessions.put(id, drive);
                            Map<String, Object> data = new HashMap<>();
                            data.put("session", id);
                            data.put("credentials", drive.credentials.toString());
                            value = data;
                        } else {
                            String id = call.argument("session");
                            CloudDrive drive = sessions.get(id);
                            if (call.method.equals("close")) {
                                sessions.remove(id);
                                value = null;
                            } else {
                                if (drive == null)
                                    throw new IllegalStateException("Cloud session closed");
                                switch (call.method) {
                                    case "folders":
                                        value =
                                                CloudFolderBrowser.folders(
                                                        drive, call.argument("parent"));
                                        break;
                                    case "createFolder":
                                        value =
                                                CloudFolderBrowser.create(
                                                        drive,
                                                        call.argument("parent"),
                                                        call.argument("name"));
                                        break;
                                    case "selectFolder":
                                        {
                                            String folder = call.argument("folderId");
                                            if (folder == null
                                                    || folder.isEmpty()
                                                    || folder.length() > 512)
                                                throw new IllegalArgumentException(
                                                        "Invalid folder");
                                            drive.directory = folder;
                                            drive.entries();
                                            value = null;
                                            break;
                                        }
                                    case "prepare":
                                        value = drive.prepare(call.argument("folder"));
                                        break;
                                    case "list":
                                        {
                                            List<String> names = new ArrayList<>();
                                            JSONArray entries = drive.entries();
                                            for (int i = 0; i < entries.length(); i++) {
                                                String name =
                                                        entries.getJSONObject(i).optString("name");
                                                names.add(name);
                                            }
                                            value = names;
                                            break;
                                        }
                                    case "read":
                                        {
                                            String name = call.argument("name");
                                            CloudDrive.requireSlot(name);
                                            value = drive.read(name);
                                            break;
                                        }
                                    case "write":
                                        {
                                            String name = call.argument("name");
                                            byte[] bytes = call.argument("bytes");
                                            CloudDrive.requireSlot(name);
                                            if (bytes == null || bytes.length > CloudDrive.MAX)
                                                throw new IllegalArgumentException(
                                                        "Snapshot too large");
                                            drive.write(name, bytes);
                                            value = null;
                                            break;
                                        }
                                    default:
                                        throw new IllegalArgumentException(
                                                "Unsupported cloud operation");
                                }
                            }
                        }
                        final Object response = value;
                        main.post(() -> result.success(response));
                    } catch (Exception error) {
                        String safe = CloudNet.safeError(error);
                        main.post(() -> result.error("cloud_storage", safe, null));
                    }
                });
    }
}
