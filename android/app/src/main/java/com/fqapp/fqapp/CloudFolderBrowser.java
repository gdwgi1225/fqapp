package com.fqapp.fqapp;

import org.json.*;

import java.io.IOException;
import java.util.*;

/** Setup operations never create a folder while listing or authenticating. */
final class CloudFolderBrowser {
    static List<Map<String, String>> folders(CloudDrive drive, String parent) throws Exception {
        JSONArray rows;
        if (drive instanceof TianyiCloudDrive) rows = ((TianyiCloudDrive) drive).listFolder(parent);
        else if (drive instanceof MobileCloudDrive)
            rows = ((MobileCloudDrive) drive).listFolder(parent);
        else {
            QuarkCloudDrive quark = (QuarkCloudDrive) drive;
            rows = new JSONArray();
            Object cursor = null;
            Set<String> seen = new HashSet<>();
            for (int page = 0; page < 50; page++) {
                JSONObject query = CloudDrive.obj("size", 100, "sort", "file_name:asc");
                if (parent != null && !parent.isEmpty()) query.put("parent_fid", parent);
                if (cursor != null) query.put("query_cursor", cursor);
                JSONObject data = quark.authorized("/open/v1/file/list", query);
                JSONArray files = data.optJSONArray("file_list");
                if (files != null)
                    for (int i = 0; i < files.length(); i++) {
                        JSONObject file = files.getJSONObject(i);
                        if ("0".equals(file.optString("file_type")))
                            rows.put(
                                    CloudDrive.obj(
                                            "id",
                                            file.getString("fid"),
                                            "name",
                                            file.optString("filename", file.optString("file_name")),
                                            "folder",
                                            true));
                    }
                Object next = data.opt("next_query_cursor");
                if (next == null || next == JSONObject.NULL) next = data.opt("next_cursor");
                boolean empty =
                        next == null || next == JSONObject.NULL || next.toString().isEmpty();
                if (data.optBoolean("last_page", empty)) break;
                if (empty || !seen.add(next.toString()) || page == 49)
                    throw new IOException("Invalid folder pagination");
                cursor = next;
            }
        }
        List<Map<String, String>> result = new ArrayList<>();
        for (int i = 0; i < rows.length(); i++) {
            JSONObject row = rows.getJSONObject(i);
            if (!row.optBoolean("folder")) continue;
            Map<String, String> entry = new HashMap<>();
            entry.put("id", row.getString("id"));
            entry.put("name", row.getString("name"));
            result.add(entry);
        }
        return result;
    }

    static String create(CloudDrive drive, String parent, String name) throws Exception {
        if (name == null
                || name.trim().isEmpty()
                || name.length() > 64
                || name.matches(".*[/\\\\\\x00-\\x1f].*")
                || name.equals(".")
                || name.equals("..")) throw new IOException("Invalid folder name");
        for (Map<String, String> folder : folders(drive, parent))
            if (name.equals(folder.get("name"))) throw new IOException("Folder exists");
        if (drive instanceof QuarkCloudDrive) {
            JSONObject body = CloudDrive.obj("dir_path", name);
            if (parent != null && !parent.isEmpty()) body.put("pdir_fid", parent);
            return ((QuarkCloudDrive) drive).authorized("/open/v1/dir", body).getString("fid");
        }
        if (drive instanceof TianyiCloudDrive)
            return ((TianyiCloudDrive) drive)
                    .api(
                            "open/file/createFolder.action",
                            "GET",
                            TianyiCloudDrive.map("parentFolderId", parent, "folderName", name))
                    .getString("id");
        return ((MobileCloudDrive) drive)
                .post(
                        "/file/create",
                        CloudDrive.obj(
                                "parentFileId",
                                parent,
                                "name",
                                name,
                                "description",
                                "",
                                "type",
                                "folder",
                                "fileRenameMode",
                                "refuse"))
                .getString("fileId");
    }
}
