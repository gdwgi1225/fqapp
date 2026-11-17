package com.fqapp.fqapp;

import android.net.Uri;
import android.util.Base64;

import org.json.*;

import java.io.IOException;
import java.text.SimpleDateFormat;
import java.util.*;

final class MobileCloudDrive extends CloudDrive {
    String personal;

    MobileCloudDrive(String credential) throws Exception {
        super(credential);
    }

    String authorization() throws Exception {
        return credentials.getString("access_token");
    }

    static String signature(String body, String time, String random) throws Exception {
        char[] sorted = Uri.encode(body, "!'()*-._~").toCharArray();
        Arrays.sort(sorted);
        String base = Base64.encodeToString(bytes(new String(sorted)), Base64.NO_WRAP);
        return digest(
                        "MD5",
                        bytes(
                                digest("MD5", bytes(base))
                                        + digest("MD5", bytes(time + ":" + random))))
                .toUpperCase(Locale.ROOT);
    }

    JSONObject call(String url, JSONObject body, boolean isPersonal) throws Exception {
        Uri uri = Uri.parse(url);
        String host = uri.getHost();
        if (!"https".equals(uri.getScheme())
                || host == null
                || !(host.equals("139.com")
                        || host.endsWith(".139.com")
                        || host.equals("10086.cn")
                        || host.endsWith(".10086.cn")))
            throw new IOException("Untrusted Mobile API host");
        SimpleDateFormat format = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US);
        format.setTimeZone(TimeZone.getTimeZone("Asia/Shanghai"));
        String time = format.format(new Date()),
                random = UUID.randomUUID().toString().replace("-", "").substring(0, 16),
                json = body.toString();
        Map<String, String> headers =
                CloudNet.headers(
                        "Content-Type",
                        "application/json;charset=UTF-8",
                        "Accept",
                        "application/json, text/plain, */*",
                        "Authorization",
                        authorization(),
                        "Cms-Device",
                        "default",
                        "Mcloud-Channel",
                        "1000101",
                        "Mcloud-Client",
                        "10701",
                        "Mcloud-Sign",
                        time + "," + random + "," + signature(json, time, random),
                        "Mcloud-Version",
                        "7.14.0",
                        "Origin",
                        "https://yun.139.com",
                        "Referer",
                        "https://yun.139.com/w/",
                        "x-DeviceInfo",
                        "||9|7.14.0|chrome|120.0.0.0|||windows 10||zh-CN|||",
                        "x-huawei-channelSrc",
                        "10000034",
                        "x-inner-ntwk",
                        "2",
                        "x-m4c-caller",
                        "PC",
                        "x-m4c-src",
                        "10002",
                        "x-SvcType",
                        "1",
                        "Inner-Hcy-Router-Https",
                        "1");
        if (isPersonal)
            headers.putAll(
                    CloudNet.headers(
                            "Caller",
                            "web",
                            "Mcloud-Route",
                            "001",
                            "X-Yun-Api-Version",
                            "v1",
                            "X-Yun-App-Channel",
                            "10000034",
                            "X-Yun-Channel-Source",
                            "10000034",
                            "X-Yun-Client-Info",
                            "||9|7.14.0|chrome|120.0.0.0|||windows 10||zh-CN|||dW5kZWZpbmVk||",
                            "X-Yun-Module-Type",
                            "100",
                            "X-Yun-Svc-Type",
                            "1"));
        CloudNet.Response response =
                CloudNet.request("POST", url, headers, bytes(json), 2 * 1024 * 1024);
        if (response.status != 200) throw new IOException("Mobile HTTP " + response.status);
        JSONObject result = new JSONObject(response.text());
        if (!result.optBoolean("success")) {
            String message = result.optString("message").toLowerCase(Locale.ROOT);
            String category =
                    message.contains("rename")
                            ? "rename_parameter"
                            : message.contains("参数")
                                    ? "parameter"
                                    : message.contains("权限")
                                            ? "permission"
                                            : message.contains("签名")
                                                    ? "signature"
                                                    : message.contains("会员")
                                                            ? "membership"
                                                            : "other";
            throw new IOException(
                    "Mobile service "
                            + TianyiCloudDrive.safeCode(result.optString("code"))
                            + " at "
                            + uri.getPath()
                            + " ("
                            + category
                            + ")");
        }
        return result;
    }

    JSONObject post(String path, JSONObject body) throws Exception {
        JSONObject data = call(personal + path, body, true).optJSONObject("data");
        return data == null ? new JSONObject() : data;
    }

    @Override
    void authenticate(boolean force) throws Exception {
        String auth = authorization();
        if (!auth.startsWith("Basic ")) throw new IOException("Mobile login required");
        String[] fields =
                new String(
                                Base64.decode(auth.substring(6), Base64.DEFAULT),
                                java.nio.charset.StandardCharsets.UTF_8)
                        .split(":", 3);
        if (fields.length != 3) throw new IOException("Mobile credential format invalid");
        JSONObject route =
                call(
                                "https://user-njs.yun.139.com/user/route/qryRoutePolicy",
                                obj(
                                        "userInfo",
                                        obj(
                                                "userType",
                                                1,
                                                "accountType",
                                                1,
                                                "accountName",
                                                fields[1]),
                                        "modAddrType",
                                        1),
                                false)
                        .getJSONObject("data");
        JSONArray policies = route.getJSONArray("routePolicyList");
        for (int i = 0; i < policies.length(); i++) {
            JSONObject p = policies.getJSONObject(i);
            if ("personal".equals(p.optString("modName"))) personal = p.optString("httpsUrl");
        }
        if (personal == null || personal.isEmpty())
            throw new IOException("Mobile personal route unavailable");
        while (personal.endsWith("/")) personal = personal.substring(0, personal.length() - 1);
    }

    JSONArray listFolder(String folder) throws Exception {
        JSONArray all = new JSONArray();
        String cursor = "";
        Set<String> seen = new HashSet<>();
        for (int page = 0; page < 100; page++) {
            JSONObject data =
                    post(
                            "/file/list",
                            obj(
                                    "parentFileId",
                                    folder,
                                    "pageInfo",
                                    obj("pageCursor", cursor, "pageSize", 100),
                                    "orderBy",
                                    "updated_at",
                                    "orderDirection",
                                    "DESC"));
            JSONArray files = data.getJSONArray("items");
            for (int i = 0; i < files.length(); i++) {
                JSONObject f = files.getJSONObject(i);
                all.put(
                        obj(
                                "name",
                                f.optString("name"),
                                "id",
                                f.optString("fileId"),
                                "folder",
                                "folder".equals(f.optString("type"))));
            }
            String next = data.isNull("nextPageCursor") ? "" : data.optString("nextPageCursor");
            if (next.isEmpty()) return all;
            if (!seen.add(next)) throw new IOException("Invalid Mobile pagination");
            cursor = next;
        }
        throw new IOException("Mobile directory exceeds sync limit");
    }

    @Override
    String prepare(String folder) throws Exception {
        requireFolder(folder);
        JSONArray roots = listFolder("/");
        for (int i = 0; i < roots.length(); i++) {
            JSONObject f = roots.getJSONObject(i);
            if (!folder.equals(f.optString("name"))) continue;
            if (!f.optBoolean("folder")) throw new IOException("Sync path is not a directory");
            directory = f.getString("id");
            return directory;
        }
        directory =
                post(
                                "/file/create",
                                obj(
                                        "parentFileId",
                                        "/",
                                        "name",
                                        folder,
                                        "description",
                                        "",
                                        "type",
                                        "folder",
                                        "fileRenameMode",
                                        "refuse"))
                        .getString("fileId");
        return directory;
    }

    @Override
    JSONArray entries() throws Exception {
        return listFolder(directory);
    }

    @Override
    byte[] read(String name) throws Exception {
        requireSlot(name);
        JSONObject f = find(name);
        if (f == null) return null;
        JSONObject data = post("/file/getDownloadUrl", obj("fileId", f.getString("id")));
        String url =
                data.optBoolean("cdnSwitch") && !data.optString("cdnUrl").isEmpty()
                        ? data.getString("cdnUrl")
                        : data.getString("url");
        CloudNet.Response result =
                CloudNet.request(
                        "GET",
                        https(url),
                        CloudNet.headers("Referer", "https://yun.139.com/"),
                        null,
                        MAX);
        if (result.status != 200) throw new IOException("Mobile download HTTP " + result.status);
        return result.body;
    }

    @Override
    void write(String name, byte[] payload) throws Exception {
        requireSlot(name);
        if (payload.length > MAX) throw new IOException("Snapshot too large");
        JSONObject prior = find(name);
        String hash = digest("SHA-256", payload);
        JSONObject body =
                obj(
                        "contentHash",
                        hash,
                        "contentHashAlgorithm",
                        "SHA256",
                        "contentType",
                        "application/octet-stream",
                        "parallelUpload",
                        false,
                        "partInfos",
                        new JSONArray()
                                .put(
                                        obj(
                                                "partNumber",
                                                1,
                                                "partSize",
                                                payload.length,
                                                "parallelHashCtx",
                                                obj("partOffset", 0))),
                        "size",
                        payload.length,
                        "parentFileId",
                        directory,
                        "name",
                        name,
                        "type",
                        "file",
                        "fileRenameMode",
                        "refuse");
        if (prior != null) body.put("fileId", prior.getString("id"));
        JSONObject data = post("/file/create", body);
        String id = data.getString("fileId");
        JSONArray parts = data.optJSONArray("partInfos");
        if (!data.optBoolean("exist") && parts != null) {
            if (parts.length() != 1) throw new IOException("Unsupported Mobile upload parts");
            CloudNet.Response put =
                    CloudNet.exactPut(
                            https(parts.getJSONObject(0).getString("uploadUrl")),
                            CloudNet.headers(
                                    "Content-Type",
                                    "application/octet-stream",
                                    "Origin",
                                    "https://yun.139.com",
                                    "Referer",
                                    "https://yun.139.com/"),
                            payload,
                            128 * 1024);
            if (put.status < 200 || put.status >= 300)
                throw new IOException("Mobile data upload HTTP " + put.status);
            post(
                    "/file/complete",
                    obj(
                            "contentHash",
                            hash,
                            "contentHashAlgorithm",
                            "SHA256",
                            "fileId",
                            id,
                            "uploadId",
                            data.getString("uploadId")));
        }
        if (data.has("fileName") && !name.equals(data.getString("fileName")))
            throw new IOException("Mobile renamed a fixed snapshot; sync stopped");
    }
}
