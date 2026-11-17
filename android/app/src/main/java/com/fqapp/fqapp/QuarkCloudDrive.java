package com.fqapp.fqapp;

import android.net.Uri;

import org.json.*;

import java.io.IOException;
import java.util.*;

/** Official Skill/Agent API, with a per-installation device identifier. */
final class QuarkCloudDrive extends CloudDrive {
    // Public parameters distributed in Quark's official Skill, not user secrets.
    static final String CLIENT = "third_party_agent", SIGN = "cf134812e2de4032bd1cb7c3727e84b3";
    static final String AGENT = "fqapp",
            DEVICE_NAME = "什锦铺 Android",
            WORK_DIR = DEFAULT_SYNC_FOLDER_NAME;

    QuarkCloudDrive(String credential) throws Exception {
        super(credential);
    }

    JSONObject api(String method, String path, JSONObject query, JSONObject body) throws Exception {
        Uri.Builder url =
                Uri.parse("https://open-api-drive.quark.cn" + path)
                        .buildUpon()
                        .appendQueryParameter("req_id", UUID.randomUUID().toString());
        if (query != null)
            for (Iterator<String> it = query.keys(); it.hasNext(); ) {
                String key = it.next();
                url.appendQueryParameter(key, query.getString(key));
            }
        String time = Long.toString(System.currentTimeMillis());
        Map<String, String> headers =
                CloudNet.headers(
                        "Content-Type",
                        "application/json",
                        "Accept",
                        "application/json",
                        "x-pan-client-id",
                        CLIENT,
                        "x-pan-tm",
                        time,
                        "x-pan-token",
                        digest("SHA-256", bytes(method + "&" + path + "&" + time + "&" + SIGN)));
        CloudNet.Response response =
                CloudNet.request(
                        method,
                        url.build().toString(),
                        headers,
                        body == null ? null : bytes(body.toString()),
                        2 * 1024 * 1024);
        if (response.status != 200) throw new IOException("Quark HTTP " + response.status);
        JSONObject result = new JSONObject(response.text());
        if (result.optInt("status", -1) != 0)
            throw new IOException("Quark service " + result.optInt("errno", -1));
        return result.optJSONObject("data") == null
                ? new JSONObject()
                : result.getJSONObject("data");
    }

    JSONObject authorized(String path, JSONObject body) throws Exception {
        return api(
                "POST",
                path,
                obj(
                        "access_token",
                        credentials.getString("access_token"),
                        "device_id",
                        credentials.optString("device_id"),
                        "platform",
                        "android"),
                body);
    }

    JSONObject beginLogin() throws Exception {
        String device = "fqapp-" + UUID.randomUUID();
        credentials.put("client_device_id", device);
        JSONObject data =
                api(
                        "POST",
                        "/agent/v1/get_authorize_page_url",
                        null,
                        obj(
                                "client_device_id",
                                device,
                                "device_name",
                                DEVICE_NAME,
                                "agent_id",
                                AGENT,
                                "client_id",
                                CLIENT,
                                "work_dir",
                                WORK_DIR,
                                "is_cloud_agent",
                                "false",
                                "is_unsure_agent",
                                "true"));
        Uri base = Uri.parse(data.getString("authorize_page_url"));
        if (!"https".equals(base.getScheme())
                || !"pan.quark.cn".equals(base.getHost())
                || !"/open/v1/oauth/agent".equals(base.getPath()))
            throw new IOException("Untrusted authorization page");
        Uri.Builder url =
                base.buildUpon()
                        .appendQueryParameter("client_id", CLIENT)
                        .appendQueryParameter("scope", "clouddrive.base clouddrive.netdisk")
                        .appendQueryParameter("client_device_id", device)
                        .appendQueryParameter("device_name", DEVICE_NAME)
                        .appendQueryParameter("agent_id", AGENT);
        if (base.getQueryParameter("device_id") == null)
            url.appendQueryParameter("device_id", data.getString("device_id"));
        return obj("page_code", data.getString("page_code"), "url", url.build().toString());
    }

    boolean pollLogin(String page) throws Exception {
        JSONObject state =
                api("GET", "/agent/v1/oauth/get_aac_by_pagecode", obj("page_code", page), null);
        if (!"success".equals(state.optString("status"))
                || state.optString("agent_auth_code").isEmpty()) return false;
        JSONObject token =
                api(
                        "GET",
                        "/agent/v1/oauth/agent_auth_code",
                        obj(
                                "agent_auth_code",
                                state.getString("agent_auth_code"),
                                "client_device_id",
                                credentials.getString("client_device_id"),
                                "device_name",
                                DEVICE_NAME,
                                "agent_id",
                                AGENT,
                                "work_dir",
                                WORK_DIR),
                        null);
        if (token.optString("access_token").isEmpty())
            throw new IOException("Authorization returned no token");
        for (Iterator<String> it = token.keys(); it.hasNext(); ) {
            String key = it.next();
            credentials.put(key, token.get(key));
        }
        return true;
    }

    @Override
    void authenticate(boolean force) throws Exception {
        if (credentials.optString("access_token").isEmpty())
            throw new IOException("Quark login required");
        long expires = credentials.optLong("access_token_expires_at", 0);
        if (expires > 0 && expires < 100000000000L) expires *= 1000;
        if (force || (expires > 0 && expires < System.currentTimeMillis() + 120000)) {
            String refresh = credentials.optString("refresh_token");
            if (refresh.isEmpty()) throw new IOException("Quark login required");
            JSONObject updated =
                    api(
                            "POST",
                            "/agent/v1/oauth/access_token/rotate",
                            null,
                            obj(
                                    "refresh_token",
                                    refresh,
                                    "device_id",
                                    credentials.getString("device_id")));
            if (updated.optString("access_token").isEmpty())
                throw new IOException("Quark refresh returned no token");
            for (Iterator<String> it = updated.keys(); it.hasNext(); ) {
                String key = it.next();
                credentials.put(key, updated.get(key));
            }
            credentials.put(
                    "access_token_expires_at",
                    System.currentTimeMillis() + updated.optLong("expires_in", 7200) * 1000);
        }
    }

    @Override
    String prepare(String folder) throws Exception {
        requireFolder(folder);
        directory = authorized("/open/v1/dir", obj("dir_path", folder)).getString("fid");
        return directory;
    }

    @Override
    JSONArray entries() throws Exception {
        JSONArray all = new JSONArray();
        Object cursor = null;
        Set<String> cursors = new HashSet<>();
        for (int page = 0; page < 50; page++) {
            JSONObject query = obj("parent_fid", directory, "size", 100, "sort", "file_name:asc");
            if (cursor != null) query.put("query_cursor", cursor);
            JSONObject data = authorized("/open/v1/file/list", query);
            JSONArray files = data.optJSONArray("file_list");
            if (files != null)
                for (int i = 0; i < files.length(); i++) {
                    JSONObject f = files.getJSONObject(i);
                    String name = f.optString("filename", f.optString("file_name"));
                    if (name.isEmpty() || f.optString("fid").isEmpty())
                        throw new IOException("Invalid Quark file listing");
                    all.put(obj("name", name, "id", f.getString("fid")));
                }
            Object next = data.opt("next_query_cursor");
            if (next == null || next == JSONObject.NULL) next = data.opt("next_cursor");
            boolean empty = next == null || next == JSONObject.NULL || next.toString().isEmpty();
            if (data.optBoolean("last_page", empty)) return all;
            if (empty || !cursors.add(next.toString()))
                throw new IOException("Invalid Quark pagination");
            cursor = next;
        }
        throw new IOException("Quark directory exceeds sync limit");
    }

    @Override
    byte[] read(String name) throws Exception {
        requireSlot(name);
        JSONObject file = find(name);
        if (file == null) return null;
        String url =
                authorized("/open/v1/file/get_download_url", obj("fid", file.getString("id")))
                        .getString("download_url");
        requireTransferHost(url);
        String host = Uri.parse(url).getHost();
        Map<String, String> headers =
                host.equals("quark.cn") || host.endsWith(".quark.cn")
                        ? CloudNet.headers(
                                "Cookie",
                                "x_pan_client_id="
                                        + CLIENT
                                        + ";x_pan_access_token="
                                        + credentials.getString("access_token"))
                        : Collections.emptyMap();
        CloudNet.Response result = CloudNet.request("GET", url, headers, null, MAX);
        if (result.status != 200) throw new IOException("Quark download HTTP " + result.status);
        return result.body;
    }

    static void requireTransferHost(String url) throws IOException {
        Uri uri = Uri.parse(url);
        String host = uri.getHost();
        if (!"https".equals(uri.getScheme())
                || host == null
                || !(host.equals("quark.cn")
                        || host.endsWith(".quark.cn")
                        || host.endsWith(".aliyuncs.com")))
            throw new IOException("Untrusted Quark transfer host");
    }

    @Override
    void write(String name, byte[] payload) throws Exception {
        requireSlot(name);
        if (payload.length > MAX) throw new IOException("Snapshot too large");
        // QuarkOpen explicitly advertises NoOverwriteUpload. SyncExchange only
        // writes the inactive a/b slot, so its counterpart remains readable
        // throughout delete/create and across a failed transfer.
        JSONObject prior = find(name);
        if (prior != null) {
            authorized(
                    "/open/v1/file/delete",
                    obj("action_type", 1, "fid_list", new JSONArray().put(prior.getString("id"))));
            boolean removed = false;
            for (int attempt = 0; attempt < 10; attempt++) {
                if (find(name) == null) {
                    removed = true;
                    break;
                }
                Thread.sleep(500);
            }
            if (!removed) throw new IOException("Quark inactive snapshot replacement not ready");
        }
        JSONObject pre =
                authorized(
                        "/open/v1/file/upload_pre",
                        obj(
                                "file_name",
                                name,
                                "size",
                                payload.length,
                                "sha1",
                                digest("SHA-1", payload),
                                "md5",
                                digest("MD5", payload),
                                "pdir_fid",
                                directory,
                                "format_type",
                                "application/json",
                                "parallel_upload",
                                true,
                                "hash_update",
                                false,
                                "same_path_file_reuse",
                                true,
                                "same_path_reuse",
                                true,
                                "device_id",
                                credentials.optString("device_id"),
                                "device_name",
                                DEVICE_NAME,
                                "agent_id",
                                AGENT));
        if (pre.optBoolean("finish")) return;
        String task = pre.getString("task_id");
        JSONObject hash =
                authorized(
                        "/open/v1/file/update/hash",
                        obj(
                                "task_id",
                                task,
                                "sha1",
                                digest("SHA-1", payload),
                                "md5",
                                digest("MD5", payload)));
        if (hash.optBoolean("finish")) return;
        JSONObject urls =
                authorized(
                        "/open/v1/file/get_upload_urls",
                        obj(
                                "task_id",
                                task,
                                "part_info_list",
                                new JSONArray()
                                        .put(obj("part_number", 1, "part_size", payload.length))));
        JSONArray parts = urls.getJSONArray("upload_urls");
        if (parts.length() != 1) throw new IOException("Unsupported Quark upload parts");
        JSONObject part = parts.getJSONObject(0);
        String url = part.getString("upload_url");
        requireTransferHost(url);
        JSONObject common = urls.optJSONObject("common_headers");
        if (common == null) common = pre.optJSONObject("common_headers");
        Map<String, String> headers = new LinkedHashMap<>();
        if (common != null)
            for (Iterator<String> it = common.keys(); it.hasNext(); ) {
                String key = it.next();
                headers.put(key, common.getString(key));
            }
        headers.put("Authorization", part.getJSONObject("signature_info").getString("signature"));
        CloudNet.Response uploaded = CloudNet.exactPut(url, headers, payload, 128 * 1024);
        if (uploaded.status < 200 || uploaded.status >= 300)
            throw new IOException("Quark upload HTTP " + uploaded.status);
        String etag = "";
        for (Map.Entry<String, List<String>> entry : uploaded.headers.entrySet())
            if ("ETag".equalsIgnoreCase(entry.getKey())) etag = entry.getValue().get(0);
        if (etag.isEmpty()) throw new IOException("Quark upload missing ETag");
        JSONObject complete =
                authorized(
                        "/open/v1/file/upload_finish",
                        obj(
                                "task_id",
                                task,
                                "part_info_list",
                                new JSONArray().put(obj("part_number", 1, "etag", etag))));
        if (!complete.optBoolean("finish")) throw new IOException("Quark upload not committed");
        // The upload response and listing may expose different id forms.
        // Verify visibility here; SyncExchange then reads this exact name and
        // compares every byte, which detects stale data or silent renaming.
        for (int attempt = 0; attempt < 8; attempt++) {
            JSONObject found = find(name);
            if (found != null) return;
            if (attempt < 7) Thread.sleep(700);
        }
        throw new IOException("Quark fixed snapshot missing after upload");
    }
}
