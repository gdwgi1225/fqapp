package com.fqapp.fqapp;

import android.net.Uri;
import android.util.Base64;

import org.json.*;

import java.io.IOException;
import java.security.*;
import java.security.spec.X509EncodedKeySpec;
import java.util.*;

import javax.crypto.*;
import javax.crypto.spec.SecretKeySpec;

final class TianyiCloudDrive extends CloudDrive {
    JSONObject rsa;

    TianyiCloudDrive(String credential) throws Exception {
        super(credential);
    }

    static Map<String, String> map(String... values) {
        return CloudNet.headers(values);
    }

    static String join(Map<String, String> values, boolean encode) {
        StringBuilder result = new StringBuilder();
        for (Map.Entry<String, String> entry : values.entrySet()) {
            if (result.length() > 0) result.append('&');
            result.append(encode ? Uri.encode(entry.getKey()) : entry.getKey())
                    .append('=')
                    .append(encode ? Uri.encode(entry.getValue()) : entry.getValue());
        }
        return result.toString();
    }

    JSONObject api(String path, String method, Map<String, String> params) throws Exception {
        String token = credentials.getString("access_token"),
                time = Long.toString(System.currentTimeMillis());
        TreeMap<String, String> signed = new TreeMap<>(params);
        signed.put("AccessToken", token);
        signed.put("Timestamp", time);
        Map<String, String> headers =
                map(
                        "Accept",
                        "application/json;charset=UTF-8",
                        "Content-Type",
                        "application/x-www-form-urlencoded;charset=UTF-8",
                        "AccessToken",
                        token,
                        "Timestamp",
                        time,
                        "Signature",
                        digest("MD5", bytes(join(signed, false))),
                        "Sign-Type",
                        "1",
                        "X-Request-ID",
                        UUID.randomUUID().toString().replace("-", ""),
                        "Referer",
                        "https://h5.cloud.189.cn/");
        String url = "https://api.cloud.189.cn/" + path;
        byte[] body = null;
        if (method.equals("POST")) body = bytes(join(params, true));
        else if (!params.isEmpty()) url += "?" + join(params, true);
        CloudNet.Response response = CloudNet.request(method, url, headers, body, 2 * 1024 * 1024);
        if (response.status != 200) throw new IOException("Tianyi HTTP " + response.status);
        JSONObject result = new JSONObject(response.text());
        String code = result.optString("res_code", "0");
        if (!code.equals("0") || !result.optString("errorCode").isEmpty())
            throw new IOException("Tianyi service " + safeCode(code) + "; login may need renewal");
        return result;
    }

    static String safeCode(String value) {
        return value.matches("[a-zA-Z0-9_-]{1,50}") ? value : "rejected";
    }

    JSONObject upload(String path, Map<String, String> params) throws Exception {
        if (rsa == null) rsa = api("open/security/generateRsaKey.action", "GET", map());
        String token = credentials.getString("access_token"),
                plain = join(params, false),
                secret = digest("MD5", bytes(plain)),
                time = Long.toString(System.currentTimeMillis());
        Cipher aes = Cipher.getInstance("AES/ECB/PKCS5Padding");
        aes.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(bytes(secret.substring(0, 16)), "AES"));
        String encrypted = hex(aes.doFinal(bytes(plain))), uri = "/person/" + path;
        Mac mac = Mac.getInstance("HmacSHA1");
        mac.init(new SecretKeySpec(bytes(secret), "HmacSHA1"));
        String signature =
                hex(
                        mac.doFinal(
                                bytes(
                                        "token="
                                                + token
                                                + "&Operate=GET&RequestURI="
                                                + uri
                                                + "&Date="
                                                + time
                                                + "&params="
                                                + encrypted)));
        String pem =
                rsa.getString("pubKey")
                        .replace("-----BEGIN PUBLIC KEY-----", "")
                        .replace("-----END PUBLIC KEY-----", "")
                        .replaceAll("\\s", "");
        PublicKey key =
                KeyFactory.getInstance("RSA")
                        .generatePublic(new X509EncodedKeySpec(Base64.decode(pem, Base64.DEFAULT)));
        Cipher enc = Cipher.getInstance("RSA/ECB/PKCS1Padding");
        enc.init(Cipher.ENCRYPT_MODE, key);
        Map<String, String> headers =
                map(
                        "Accept",
                        "application/json;charset=UTF-8",
                        "token",
                        token,
                        "Signature",
                        signature,
                        "EncryptionText",
                        Base64.encodeToString(enc.doFinal(bytes(secret)), Base64.NO_WRAP),
                        "X-Request-Date",
                        time,
                        "X-Request-ID",
                        UUID.randomUUID().toString(),
                        "PkId",
                        rsa.getString("pkId"),
                        "SignType",
                        "1",
                        "Secret",
                        secret);
        CloudNet.Response response =
                CloudNet.request(
                        "GET",
                        "https://upload.cloud.189.cn" + uri + "?params=" + encrypted,
                        headers,
                        null,
                        2 * 1024 * 1024);
        if (response.status != 200) throw new IOException("Tianyi upload HTTP " + response.status);
        JSONObject result = new JSONObject(response.text());
        if (!"SUCCESS".equals(result.optString("code")))
            throw new IOException("Tianyi upload service " + safeCode(result.optString("code")));
        return result;
    }

    @Override
    void authenticate(boolean force) throws Exception {
        if (credentials.optString("access_token").isEmpty())
            throw new IOException("Tianyi login required");
        // H5 grants do not expose a refresh token. Renewal uses the official H5
        // login with its retained WebView session, never a guessed token API.
    }

    JSONArray listFolder(String folder) throws Exception {
        JSONArray all = new JSONArray();
        for (int page = 1; page <= 100; page++) {
            JSONObject result =
                    api(
                            "open/file/listFiles.action",
                            "GET",
                            map(
                                    "folderId",
                                    folder,
                                    "pageNum",
                                    Integer.toString(page),
                                    "pageSize",
                                    "100",
                                    "mediaType",
                                    "0",
                                    "iconOption",
                                    "5",
                                    "orderBy",
                                    "lastOpTime",
                                    "descending",
                                    "true"));
            JSONObject data = result.optJSONObject("fileListAO");
            if (data == null) data = result;
            int count = 0;
            for (String kind : new String[] {"folderList", "fileList"}) {
                JSONArray items = data.optJSONArray(kind);
                if (items == null) continue;
                count += items.length();
                for (int i = 0; i < items.length(); i++) {
                    JSONObject item = items.getJSONObject(i);
                    all.put(
                            obj(
                                    "name",
                                    item.optString("name"),
                                    "id",
                                    item.optString(
                                            "id",
                                            item.optString("fileId", item.optString("folderId"))),
                                    "folder",
                                    kind.equals("folderList")));
                }
            }
            if (count < 100) return all;
        }
        throw new IOException("Tianyi directory exceeds sync limit");
    }

    @Override
    String prepare(String folder) throws Exception {
        requireFolder(folder);
        JSONArray root = listFolder("-11");
        for (int i = 0; i < root.length(); i++) {
            JSONObject entry = root.getJSONObject(i);
            if (!folder.equals(entry.optString("name"))) continue;
            if (!entry.optBoolean("folder")) throw new IOException("Sync path is not a directory");
            directory = entry.getString("id");
            return directory;
        }
        JSONObject created =
                api(
                        "open/file/createFolder.action",
                        "POST",
                        map("parentFolderId", "-11", "folderName", folder));
        directory = created.optString("id", created.optString("folderId"));
        if (directory.isEmpty()) throw new IOException("Tianyi did not return a folder id");
        return directory;
    }

    @Override
    JSONArray entries() throws Exception {
        return listFolder(directory);
    }

    @Override
    byte[] read(String name) throws Exception {
        requireSlot(name);
        JSONObject file = find(name);
        if (file == null) return null;
        JSONObject data =
                api(
                        "open/file/getFileDownloadUrl.action",
                        "GET",
                        map("fileId", file.getString("id")));
        String url = https(data.optString("fileDownloadUrl", data.optString("downloadUrl")));
        CloudNet.Response result =
                CloudNet.request("GET", url, map("Referer", "https://h5.cloud.189.cn/"), null, MAX);
        if (result.status != 200) throw new IOException("Tianyi download HTTP " + result.status);
        return result.body;
    }

    @Override
    void write(String name, byte[] payload) throws Exception {
        requireSlot(name);
        if (payload.length > MAX) throw new IOException("Snapshot too large");
        final int chunk = 10 * 1024 * 1024;
        String hash = digest("MD5", payload);
        List<byte[]> partHashes = new ArrayList<>();
        List<String> partHex = new ArrayList<>();
        for (int start = 0; start < payload.length; start += chunk) {
            byte[] h =
                    MessageDigest.getInstance("MD5")
                            .digest(
                                    Arrays.copyOfRange(
                                            payload,
                                            start,
                                            Math.min(payload.length, start + chunk)));
            partHashes.add(h);
            partHex.add(hex(h).toUpperCase(Locale.ROOT));
        }
        String slice =
                partHashes.size() <= 1 ? hash : digest("MD5", bytes(String.join("\n", partHex)));
        JSONObject data =
                upload(
                                "initMultiUpload",
                                map(
                                        "fileName",
                                        Uri.encode(name),
                                        "fileSize",
                                        Integer.toString(payload.length),
                                        "sliceSize",
                                        Integer.toString(chunk),
                                        "parentFolderId",
                                        directory,
                                        "fileMd5",
                                        hash,
                                        "sliceMd5",
                                        slice))
                        .getJSONObject("data");
        String uploadId = data.getString("uploadFileId");
        if (data.optInt("fileDataExists", 0) != 1 && !data.optBoolean("fileDataExists", false)) {
            for (int i = 0; i < partHashes.size(); i++) {
                JSONObject urls =
                        upload(
                                "getMultiUploadUrls",
                                map(
                                        "uploadFileId",
                                        uploadId,
                                        "partInfo",
                                        (i + 1)
                                                + "-"
                                                + Base64.encodeToString(
                                                        partHashes.get(i), Base64.NO_WRAP)));
                JSONObject part =
                        urls.getJSONObject("uploadUrls").getJSONObject("partNumber_" + (i + 1));
                Map<String, String> headers = new LinkedHashMap<>();
                for (String entry : Uri.decode(part.optString("requestHeader")).split("&")) {
                    int equal = entry.indexOf('=');
                    if (equal > 0)
                        headers.put(entry.substring(0, equal), entry.substring(equal + 1));
                }
                byte[] bytes =
                        Arrays.copyOfRange(
                                payload, i * chunk, Math.min(payload.length, (i + 1) * chunk));
                CloudNet.Response result =
                        CloudNet.exactPut(
                                https(part.getString("requestURL")), headers, bytes, 128 * 1024);
                if (result.status < 200 || result.status >= 300)
                    throw new IOException("Tianyi data upload HTTP " + result.status);
            }
        }
        // op 3 is the overwrite commit used by OpenList; never trash old slots.
        upload(
                "commitMultiUploadFile",
                map(
                        "uploadFileId",
                        uploadId,
                        "lazyCheck",
                        "0",
                        "fileMd5",
                        hash,
                        "sliceMd5",
                        slice,
                        "opertype",
                        "3"));
    }
}
