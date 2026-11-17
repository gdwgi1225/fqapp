package com.fqapp.fqapp;

import org.json.*;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;

/**
 * Stateful only for a single sync batch; credentials are persisted by Dart's secure store, never by
 * these clients or in diagnostic output.
 */
abstract class CloudDrive {
    static final int MAX = 32 * 1024 * 1024;
    static final String DEFAULT_SYNC_FOLDER_NAME = "什锦铺-云同步";
    final JSONObject credentials;
    String directory = "";

    CloudDrive(String credential) throws Exception {
        JSONObject parsed;
        try {
            parsed = new JSONObject(credential);
        } catch (JSONException ignored) {
            parsed = obj("access_token", credential);
        }
        credentials = parsed;
    }

    abstract void authenticate(boolean forceRefresh) throws Exception;

    abstract String prepare(String folder) throws Exception;

    abstract JSONArray entries() throws Exception;

    abstract byte[] read(String name) throws Exception;

    abstract void write(String name, byte[] bytes) throws Exception;

    JSONObject find(String name) throws Exception {
        JSONArray files = entries();
        JSONObject found = null;
        for (int i = 0; i < files.length(); i++) {
            JSONObject item = files.getJSONObject(i);
            if (!name.equals(item.optString("name"))) continue;
            if (found != null) throw new IOException("Duplicate snapshot name; sync stopped");
            found = item;
        }
        return found;
    }

    static JSONObject obj(Object... values) throws JSONException {
        JSONObject result = new JSONObject();
        for (int i = 0; i < values.length; i += 2) result.put((String) values[i], values[i + 1]);
        return result;
    }

    static byte[] bytes(String value) {
        return value.getBytes(StandardCharsets.UTF_8);
    }

    static String digest(String algorithm, byte[] value) throws Exception {
        return hex(MessageDigest.getInstance(algorithm).digest(value));
    }

    static String hex(byte[] value) {
        StringBuilder result = new StringBuilder();
        for (byte b : value) result.append(String.format(Locale.ROOT, "%02x", b & 255));
        return result.toString();
    }

    static String https(String url) throws IOException {
        if (url.startsWith("//")) url = "https:" + url;
        if (url.startsWith("http://")) url = "https://" + url.substring(7);
        if (!url.startsWith("https://")) throw new IOException("Invalid transfer URL");
        return url;
    }

    static void requireSlot(String name) throws IOException {
        if (!name.matches("[a-f0-9]{32}\\.[ab]\\.json"))
            throw new IOException("Invalid snapshot name");
    }

    static void requireFolder(String folder) throws IOException {
        if (folder == null
                || folder.trim().isEmpty()
                || folder.length() > 64
                || folder.equals(".")
                || folder.equals("..")
                || folder.indexOf('/') >= 0
                || folder.indexOf('\\') >= 0
                || folder.chars().anyMatch(character -> character < 0x20)) {
            throw new IOException("Invalid sync directory name");
        }
    }
}
