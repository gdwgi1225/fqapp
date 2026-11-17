package com.fqapp.fqapp;

import android.os.Handler;
import android.os.Looper;

import com.hierynomus.msdtyp.AccessMask;
import com.hierynomus.msfscc.FileAttributes;
import com.hierynomus.msfscc.fileinformation.FileIdBothDirectoryInformation;
import com.hierynomus.msfscc.fileinformation.FileStandardInformation;
import com.hierynomus.mssmb2.*;
import com.hierynomus.smbj.SMBClient;
import com.hierynomus.smbj.SmbConfig;
import com.hierynomus.smbj.auth.AuthenticationContext;
import com.hierynomus.smbj.auth.NtlmAuthenticator;
import com.hierynomus.smbj.connection.Connection;
import com.hierynomus.smbj.session.Session;
import com.hierynomus.smbj.share.DiskShare;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.*;

import org.apache.commons.net.ftp.*;

import java.io.*;
import java.net.URI;
import java.util.*;
import java.util.concurrent.*;

import javax.net.ssl.*;

/** Credentials live only in call arguments; never log paths, users or failures. */
public final class SyncStoragePlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
    private MethodChannel channel;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());
    private static final int MAX = 32 * 1024 * 1024;

    public void onAttachedToEngine(FlutterPluginBinding binding) {
        channel = new MethodChannel(binding.getBinaryMessenger(), "fqapp/sync_storage");
        channel.setMethodCallHandler(this);
    }

    public void onDetachedFromEngine(FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
        worker.shutdown();
    }

    public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        if (!Arrays.asList("prepare", "list", "read", "write", "folders", "createFolder")
                .contains(call.method)) {
            result.notImplemented();
            return;
        }
        worker.execute(
                () -> {
                    try {
                        Map<String, Object> args = call.arguments();
                        String name = text(args, "name");
                        if ((call.method.equals("read") || call.method.equals("write"))
                                && !name.matches("[a-f0-9]{32}\\.[ab]\\.json"))
                            throw new IOException();
                        Object value =
                                "smb".equals(text(args, "provider"))
                                        ? smb(call.method, args, name)
                                        : ftp(call.method, args, name);
                        main.post(() -> result.success(value));
                    } catch (Exception ignored) {
                        main.post(() -> result.error("sync_storage", "连接、认证或文件操作失败", null));
                    }
                });
    }

    private static String text(Map<String, Object> args, String key) {
        Object value = args.get(key);
        return value instanceof String ? (String) value : "";
    }

    private static URI address(Map<String, Object> args, String scheme) throws Exception {
        URI uri = new URI(text(args, "endpoint"));
        if (!scheme.equals(uri.getScheme())
                || uri.getHost() == null
                || uri.getRawUserInfo() != null
                || uri.getRawQuery() != null
                || uri.getRawFragment() != null
                || uri.getPath().contains("..")
                || uri.getPath().contains("\r")
                || uri.getPath().contains("\n")) throw new IOException();
        return uri;
    }

    private static byte[] bounded(InputStream stream) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buffer = new byte[16384];
        int count;
        while ((count = stream.read(buffer)) != -1) {
            if (out.size() + count > MAX) throw new IOException();
            out.write(buffer, 0, count);
        }
        return out.toByteArray();
    }

    static Object ftp(String action, Map<String, Object> args, String name) throws Exception {
        return ftp(action, args, name, null);
    }

    // Package-local trust injection is used only by the debug loopback harness;
    // MethodChannel callers always use the system-trust overload above.
    static Object ftp(
            String action, Map<String, Object> args, String name, X509TrustManager testTrust)
            throws Exception {
        boolean tls = "ftps".equals(text(args, "provider"));
        URI uri = address(args, tls ? "ftps" : "ftp");
        boolean implicit = "true".equals(text(args, "implicit"));
        FTPClient client = tls ? new FTPSClient(implicit) : new FTPClient();
        client.setConnectTimeout(20000);
        client.setDefaultTimeout(30000);
        client.setDataTimeout(java.time.Duration.ofSeconds(40));
        client.setControlEncoding("UTF-8");
        if (tls) {
            FTPSClient secure = (FTPSClient) client;
            TrustManagerFactory factory =
                    TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
            factory.init((java.security.KeyStore) null);
            for (TrustManager trust : factory.getTrustManagers())
                if (trust instanceof X509TrustManager)
                    secure.setTrustManager((X509TrustManager) trust);
            if (testTrust != null) secure.setTrustManager(testTrust);
            secure.setEndpointCheckingEnabled(true);
        }
        try {
            client.connect(
                    uri.getHost(), uri.getPort() > 0 ? uri.getPort() : tls && implicit ? 990 : 21);
            if (!FTPReply.isPositiveCompletion(client.getReplyCode())
                    || !client.login(text(args, "username"), text(args, "password")))
                throw new IOException();
            if (tls) {
                ((FTPSClient) client).execPBSZ(0);
                ((FTPSClient) client).execPROT("P");
            }
            client.enterLocalPassiveMode();
            if (!client.setFileType(FTP.BINARY_FILE_TYPE)) throw new IOException();
            String path = uri.getPath();
            if (path.isEmpty()) path = "/";
            if (action.equals("folders")) {
                if (!client.changeWorkingDirectory(path)) throw new IOException();
                List<String> folders = new ArrayList<>();
                for (FTPFile file : client.listFiles())
                    if (file.isDirectory()
                            && !file.getName().equals(".")
                            && !file.getName().equals("..")) folders.add(file.getName());
                if (!FTPReply.isPositiveCompletion(client.getReplyCode())) throw new IOException();
                return folders;
            }
            if (path.equals("/")) throw new IOException();
            if (action.equals("createFolder")) {
                if (!client.makeDirectory(path)) throw new IOException();
                return null;
            }
            if (action.equals("prepare")) {
                if (!client.changeWorkingDirectory(path)) {
                    if (!client.makeDirectory(path) || !client.changeWorkingDirectory(path))
                        throw new IOException();
                }
                return null;
            }
            if (!client.changeWorkingDirectory(path)) throw new IOException();
            if (action.equals("list")) {
                FTPFile[] files = client.listFiles();
                if (!FTPReply.isPositiveCompletion(client.getReplyCode())) throw new IOException();
                List<String> names = new ArrayList<>();
                for (FTPFile file : files)
                    if (file.isFile() && file.getName().matches("[a-f0-9]{32}\\.[ab]\\.json"))
                        names.add(file.getName());
                return names;
            }
            if (action.equals("write")) {
                byte[] bytes = (byte[]) args.get("bytes");
                if (bytes.length > MAX) throw new IOException();
                if (!client.storeFile(name, new ByteArrayInputStream(bytes)))
                    throw new IOException();
                return null;
            }
            InputStream input = client.retrieveFileStream(name);
            if (input == null) {
                if (client.getReplyCode() == 550) return null;
                throw new IOException();
            }
            byte[] bytes;
            try (InputStream stream = input) {
                bytes = bounded(stream);
            }
            if (!client.completePendingCommand()) throw new IOException();
            return bytes;
        } finally {
            try {
                if (client.isConnected()) client.disconnect();
            } catch (IOException ignored) {
            }
        }
    }

    static Object smb(String action, Map<String, Object> args, String name) throws Exception {
        URI uri = address(args, "smb");
        if (uri.getPath() == null || uri.getPath().split("/").length < 2) throw new IOException();
        String[] parts = uri.getPath().split("/", 3);
        String root = parts.length > 2 ? parts[2].replace('/', '\\') : "";
        while (root.endsWith("\\")) root = root.substring(0, root.length() - 1);
        if (root.indexOf('\\') == 0 || root.isEmpty() && !action.equals("folders"))
            throw new IOException();
        SmbConfig config =
                SmbConfig.builder()
                        .withAuthenticators(new NtlmAuthenticator.Factory())
                        .withTimeout(30, TimeUnit.SECONDS)
                        .withSoTimeout(40, TimeUnit.SECONDS)
                        .withSigningRequired(true)
                        .build();
        // SMBJ supports only SMB2/3. Signing remains mandatory; no SMB1 or
        // unsigned fallback is enabled to work around an incompatible server.
        try (SMBClient client = new SMBClient(config);
                Connection connection =
                        client.connect(uri.getHost(), uri.getPort() > 0 ? uri.getPort() : 445)) {
            Session session =
                    connection.authenticate(
                            new AuthenticationContext(
                                    text(args, "username"),
                                    text(args, "password").toCharArray(),
                                    text(args, "domain")));
            try (DiskShare share = (DiskShare) session.connectShare(parts[1])) {
                if (action.equals("folders")) {
                    List<String> folders = new ArrayList<>();
                    for (FileIdBothDirectoryInformation entry : share.list(root))
                        if ((entry.getFileAttributes()
                                                & FileAttributes.FILE_ATTRIBUTE_DIRECTORY
                                                        .getValue())
                                        != 0
                                && !entry.getFileName().equals(".")
                                && !entry.getFileName().equals(".."))
                            folders.add(entry.getFileName());
                    return folders;
                }
                if (action.equals("createFolder")) {
                    if (smbExists(share, root, true)) throw new IOException();
                    share.mkdir(root);
                    return null;
                }
                if (action.equals("prepare")) {
                    if (!smbExists(share, root, true)) share.mkdir(root);
                    return null;
                }
                if (action.equals("list")) {
                    List<String> names = new ArrayList<>();
                    for (FileIdBothDirectoryInformation entry : share.list(root)) {
                        if ((entry.getFileAttributes()
                                                & FileAttributes.FILE_ATTRIBUTE_DIRECTORY
                                                        .getValue())
                                        == 0
                                && entry.getFileName().matches("[a-f0-9]{32}\\.[ab]\\.json"))
                            names.add(entry.getFileName());
                    }
                    return names;
                }
                String path = root + "\\" + name;
                boolean write = action.equals("write");
                if (!write && !smbExists(share, path, false)) return null;
                try (com.hierynomus.smbj.share.File file =
                        share.openFile(
                                path,
                                EnumSet.of(
                                        write ? AccessMask.GENERIC_WRITE : AccessMask.GENERIC_READ),
                                EnumSet.of(FileAttributes.FILE_ATTRIBUTE_NORMAL),
                                SMB2ShareAccess.ALL,
                                write
                                        ? SMB2CreateDisposition.FILE_OVERWRITE_IF
                                        : SMB2CreateDisposition.FILE_OPEN,
                                EnumSet.of(SMB2CreateOptions.FILE_NON_DIRECTORY_FILE))) {
                    if (write) {
                        byte[] bytes = (byte[]) args.get("bytes");
                        if (bytes.length > MAX) throw new IOException();
                        try (OutputStream stream = file.getOutputStream()) {
                            stream.write(bytes);
                        }
                        return null;
                    }
                    // Read the bounded, advertised length without speculative
                    // read-ahead beyond EOF; small NAS servers differ in EOF handling.
                    long size =
                            file.getFileInformation(FileStandardInformation.class).getEndOfFile();
                    if (size < 0 || size > MAX) throw new IOException();
                    byte[] bytes = new byte[(int) size];
                    int offset = 0;
                    while (offset < bytes.length) {
                        int count =
                                file.read(
                                        bytes,
                                        offset,
                                        offset,
                                        Math.min(65536, bytes.length - offset));
                        if (count <= 0) throw new EOFException();
                        offset += count;
                    }
                    return bytes;
                }
            } finally {
                session.close();
            }
        }
    }

    private static boolean smbExists(DiskShare share, String path, boolean folder) {
        try {
            return folder ? share.folderExists(path) : share.fileExists(path);
        } catch (SMBApiException error) {
            long status = error.getStatusCode();
            // Servers differ in the not-found status returned by an open query.
            // Authentication and access errors still fail.
            if (status == 0xc000000fL || status == 0xc0000034L || status == 0xc000003aL)
                return false;
            throw error;
        }
    }
}
