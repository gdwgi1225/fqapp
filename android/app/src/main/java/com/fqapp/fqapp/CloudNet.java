package com.fqapp.fqapp;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

final class CloudNet {
    static final class Response {
        int status;
        byte[] body;
        Map<String, List<String>> headers;

        String text() {
            return new String(body, StandardCharsets.UTF_8);
        }
    }

    static Map<String, String> headers(String... pairs) {
        Map<String, String> h = new LinkedHashMap<>();
        for (int i = 0; i < pairs.length; i += 2) h.put(pairs[i], pairs[i + 1]);
        return h;
    }

    static Response request(
            String method, String address, Map<String, String> headers, byte[] body, int max)
            throws Exception {
        URL u = new URL(address);
        for (int redirects = 0; redirects < 6; redirects++) {
            if (!"https".equalsIgnoreCase(u.getProtocol()))
                throw new IOException("Non-HTTPS endpoint refused");
            HttpURLConnection c = (HttpURLConnection) u.openConnection();
            c.setInstanceFollowRedirects(false);
            c.setConnectTimeout(15000);
            c.setReadTimeout(25000);
            c.setRequestMethod(method);
            for (Map.Entry<String, String> h : headers.entrySet())
                c.setRequestProperty(h.getKey(), h.getValue());
            boolean hasAccept = false;
            for (String name : headers.keySet())
                if ("Accept".equalsIgnoreCase(name)) hasAccept = true;
            if (!hasAccept) c.setRequestProperty("Accept", "application/json, */*");
            if (body != null) {
                c.setDoOutput(true);
                c.setFixedLengthStreamingMode(body.length);
                try (OutputStream out = c.getOutputStream()) {
                    out.write(body);
                }
            }
            int status = c.getResponseCode();
            if (status >= 300 && status < 400 && c.getHeaderField("Location") != null) {
                if (!"GET".equals(method)) throw new IOException("API redirect refused");
                URL next = new URL(u, c.getHeaderField("Location"));
                if (!next.getHost().equalsIgnoreCase(u.getHost())) {
                    Map<String, String> safe = new LinkedHashMap<>();
                    for (Map.Entry<String, String> h : headers.entrySet())
                        if ("Accept".equalsIgnoreCase(h.getKey())
                                || "Range".equalsIgnoreCase(h.getKey())
                                || "Referer".equalsIgnoreCase(h.getKey()))
                            safe.put(h.getKey(), h.getValue());
                    headers = safe;
                }
                u = next;
                c.disconnect();
                continue;
            }
            Response r = new Response();
            r.status = status;
            r.headers = c.getHeaderFields();
            InputStream raw = status < 400 ? c.getInputStream() : c.getErrorStream();
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            if (raw != null)
                try (InputStream in = raw) {
                    byte[] buf = new byte[4096];
                    for (int n; (n = in.read(buf)) != -1; ) {
                        if (bytes.size() + n > max)
                            throw new IOException("Response exceeds diagnostic size limit");
                        bytes.write(buf, 0, n);
                    }
                }
            r.body = bytes.toByteArray();
            c.disconnect();
            return r;
        }
        throw new IOException("Too many redirects");
    }

    static String safeError(Exception e) {
        String s = e.getMessage();
        if (s == null) s = e.getClass().getSimpleName();
        s =
                s.replaceAll("https?://[^\\s]+", "[endpoint]")
                        .replaceAll(
                                "(?i)(token|cookie|authorization|code|key)\\s*[:=]\\s*[^ ,;]+",
                                "$1=[redacted]")
                        .replaceAll("[A-Za-z0-9_-]{24,}", "[redacted]")
                        .replaceAll("[0-9]{10,}", "[redacted]");
        return s.length() > 160 ? s.substring(0, 160) : s;
    }

    /**
     * OSS V4 includes Content-Type when present, even if empty. Send exactly the issued headers.
     */
    static Response exactPut(String address, Map<String, String> headers, byte[] body, int max)
            throws Exception {
        return exactRequest("PUT", address, headers, body, max);
    }

    /** Generic TLS request for WebDAV methods rejected by some URLConnection implementations. */
    static Response exactRequest(
            String method, String address, Map<String, String> headers, byte[] body, int max)
            throws Exception {
        if (!method.matches("[A-Z]+")) throw new IOException("Invalid HTTP method");
        if (body == null) body = new byte[0];
        URL url = new URL(address);
        if (!"https".equals(url.getProtocol())) throw new IOException("Non-HTTPS endpoint refused");
        int port = url.getPort() < 0 ? 443 : url.getPort();
        Socket transport = new Socket();
        transport.connect(new InetSocketAddress(url.getHost(), port), 15000);
        transport.setSoTimeout(25000);
        try (javax.net.ssl.SSLSocket socket =
                (javax.net.ssl.SSLSocket)
                        ((javax.net.ssl.SSLSocketFactory)
                                        javax.net.ssl.SSLSocketFactory.getDefault())
                                .createSocket(transport, url.getHost(), port, true)) {
            javax.net.ssl.SSLParameters params = socket.getSSLParameters();
            params.setEndpointIdentificationAlgorithm("HTTPS");
            socket.setSSLParameters(params);
            socket.startHandshake();
            String path = url.getFile().isEmpty() ? "/" : url.getFile();
            if (path.indexOf('\r') >= 0 || path.indexOf('\n') >= 0)
                throw new IOException("Invalid transfer path");
            StringBuilder head =
                    new StringBuilder(method)
                            .append(' ')
                            .append(path)
                            .append(" HTTP/1.1\r\nHost: ")
                            .append(url.getHost());
            if (port != 443) head.append(':').append(port);
            head.append("\r\nContent-Length: ")
                    .append(body.length)
                    .append("\r\nConnection: close\r\n");
            for (Map.Entry<String, String> h : headers.entrySet()) {
                if (!h.getKey().matches("[A-Za-z0-9-]+")
                        || h.getValue().indexOf('\r') >= 0
                        || h.getValue().indexOf('\n') >= 0)
                    throw new IOException("Invalid transfer header");
                if ("Host".equalsIgnoreCase(h.getKey())
                        || "Content-Length".equalsIgnoreCase(h.getKey())
                        || "Connection".equalsIgnoreCase(h.getKey())) continue;
                head.append(h.getKey()).append(": ").append(h.getValue()).append("\r\n");
            }
            OutputStream out = socket.getOutputStream();
            out.write(head.append("\r\n").toString().getBytes(StandardCharsets.ISO_8859_1));
            out.write(body);
            out.flush();
            BufferedInputStream in = new BufferedInputStream(socket.getInputStream());
            String status = httpLine(in);
            String[] statusParts = status.split(" ", 3);
            if (statusParts.length < 2) throw new IOException("Invalid transfer status");
            Response response = new Response();
            response.status = Integer.parseInt(statusParts[1]);
            response.headers = new LinkedHashMap<>();
            int headerBytes = 0;
            for (String line; !(line = httpLine(in)).isEmpty(); ) {
                headerBytes += line.length();
                if (headerBytes > 32768) throw new IOException("Transfer headers exceed limit");
                int at = line.indexOf(':');
                if (at > 0)
                    response.headers
                            .computeIfAbsent(line.substring(0, at), k -> new ArrayList<>())
                            .add(line.substring(at + 1).trim());
            }
            boolean chunked = false;
            int length = -1;
            for (Map.Entry<String, List<String>> h : response.headers.entrySet()) {
                if ("Transfer-Encoding".equalsIgnoreCase(h.getKey()))
                    chunked = h.getValue().get(0).toLowerCase(Locale.ROOT).contains("chunked");
                if ("Content-Length".equalsIgnoreCase(h.getKey()))
                    length = Integer.parseInt(h.getValue().get(0));
            }
            ByteArrayOutputStream data = new ByteArrayOutputStream();
            if (chunked) {
                while (true) {
                    String line = httpLine(in);
                    int size = Integer.parseInt(line.split(";", 2)[0].trim(), 16);
                    if (size == 0) break;
                    readExact(in, data, size, max);
                    if (!httpLine(in).isEmpty()) throw new IOException("Invalid chunk ending");
                }
            } else if (length >= 0) readExact(in, data, length, max);
            else {
                for (int b; (b = in.read()) != -1; ) {
                    if (data.size() >= max)
                        throw new IOException("Transfer response exceeds limit");
                    data.write(b);
                }
            }
            response.body = data.toByteArray();
            return response;
        } finally {
            transport.close();
        }
    }

    static String httpLine(InputStream in) throws Exception {
        ByteArrayOutputStream data = new ByteArrayOutputStream();
        for (int c; (c = in.read()) != -1; ) {
            if (c == '\n')
                return new String(data.toByteArray(), StandardCharsets.ISO_8859_1)
                        .replaceFirst("\\r$", "");
            if (data.size() > 8192) throw new IOException("HTTP line exceeds limit");
            data.write(c);
        }
        throw new EOFException("Incomplete transfer response");
    }

    static void readExact(InputStream in, ByteArrayOutputStream out, int count, int max)
            throws Exception {
        if (count < 0 || out.size() + count > max)
            throw new IOException("Transfer response exceeds limit");
        byte[] buf = new byte[Math.min(4096, Math.max(1, count))];
        while (count > 0) {
            int n = in.read(buf, 0, Math.min(count, buf.length));
            if (n < 0) throw new EOFException("Incomplete transfer body");
            out.write(buf, 0, n);
            count -= n;
        }
    }
}
