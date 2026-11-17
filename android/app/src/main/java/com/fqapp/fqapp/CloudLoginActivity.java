package com.fqapp.fqapp;

import android.app.Activity;
import android.content.*;
import android.content.res.ColorStateList;
import android.content.res.Configuration;
import android.graphics.Typeface;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.net.Uri;
import android.os.*;
import android.view.Gravity;
import android.webkit.*;
import android.widget.*;

import org.json.*;

import java.util.*;
import java.util.concurrent.*;

/**
 * Official web login and supported client handoffs. No JavaScript bridge, package/signature
 * impersonation, credential logs or system browser cookies.
 */
public final class CloudLoginActivity extends Activity {
    private WebView web;
    private FrameLayout content;
    private String provider, weiyunCode = "", quarkPage = "", lastCandidate = "";
    private QuarkCloudDrive quark;
    private Intent quarkAuthorizationIntent;
    private Button quarkRetryButton;
    private final Map<WebView, String> popupOrigins = new WeakHashMap<>();
    private boolean completed, pollBusy;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final Runnable poll =
            new Runnable() {
                public void run() {
                    if (completed) return;
                    capture();
                    pollRemote();
                    handler.postDelayed(this, 3000);
                }
            };

    @Override
    public void onCreate(Bundle state) {
        super.onCreate(state);
        provider = getIntent().getStringExtra("provider");
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setOnApplyWindowInsetsListener(
                (view, insets) -> {
                    if (android.os.Build.VERSION.SDK_INT >= 30) {
                        android.graphics.Insets bars =
                                insets.getInsets(android.view.WindowInsets.Type.systemBars());
                        view.setPadding(bars.left, bars.top, bars.right, bars.bottom);
                    } else
                        view.setPadding(
                                insets.getSystemWindowInsetLeft(),
                                insets.getSystemWindowInsetTop(),
                                insets.getSystemWindowInsetRight(),
                                insets.getSystemWindowInsetBottom());
                    return insets;
                });
        content = new FrameLayout(this);
        buildLoginLayout(layout);
        setContentView(layout);
        web = makeWeb();
        content.addView(web, new FrameLayout.LayoutParams(-1, -1));
        CookieManager.getInstance().setAcceptCookie(true);
        if ("quark".equals(provider)) {
            worker.execute(
                    () -> {
                        try {
                            quark = new QuarkCloudDrive("{}");
                            JSONObject start = quark.beginLogin();
                            quarkPage = start.getString("page_code");
                            handler.post(
                                    () -> {
                                        if (!completed) web.loadUrl(start.optString("url"));
                                    });
                        } catch (Exception error) {
                            handler.post(() -> toast("夸克授权入口暂不可用，请重试"));
                        }
                    });
        } else if ("weiyun".equals(provider)) {
            weiyunCode = UUID.randomUUID().toString().replace("-", "").substring(0, 16);
            loadWeiyunAuthorization();
        } else if ("ali".equals(provider)) web.loadUrl("https://www.alipan.com/sign/in");
        else if ("tianyi".equals(provider))
            web.loadUrl(
                    "https://api.cloud.189.cn/open/oauth2/ssoH5.action?redirectURL=https%3A%2F%2Fh5.cloud.189.cn%2Fmain.html");
        else if ("mobile139".equals(provider)) web.loadUrl("https://yun.139.com/w/");
        else {
            finish();
            return;
        }
        handler.postDelayed(poll, 1200);
    }

    private void buildLoginLayout(LinearLayout layout) {
        boolean weiyun = "weiyun".equals(provider);
        boolean quarkLogin = "quark".equals(provider);
        boolean dark =
                (getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK)
                        == Configuration.UI_MODE_NIGHT_YES;
        int surface = dark ? 0xff17191e : 0xffffffff;
        int mutedSurface = dark ? 0xff22252c : 0xfff3f5f8;
        int stroke = dark ? 0xff3c414b : 0xffd7dde6;
        int titleColor = dark ? 0xffeef0f5 : 0xff192230;
        int hintColor = dark ? 0xffb8bfcb : 0xff505c6c;
        layout.setBackgroundColor(surface);

        String heading =
                switch (provider == null ? "" : provider) {
                    case "weiyun" -> "腾讯微云授权";
                    case "ali" -> "阿里云盘登录";
                    case "quark" -> "夸克网盘授权";
                    case "tianyi" -> "天翼云盘登录";
                    case "mobile139" -> "中国移动云盘登录";
                    default -> "网盘登录";
                };
        String actionLabel = weiyun ? "继续授权" : quarkLogin ? "重新打开夸克" : "检查登录状态";
        LinearLayout header = new LinearLayout(this);
        header.setOrientation(LinearLayout.VERTICAL);
        header.setPadding(dp(16), dp(12), dp(16), dp(8));
        TextView title = new TextView(this);
        title.setText(heading);
        title.setTextSize(20);
        title.setTextColor(titleColor);
        title.setTypeface(null, Typeface.BOLD);
        if (Build.VERSION.SDK_INT >= 28) title.setAccessibilityHeading(true);
        header.addView(title);

        TextView hint = new TextView(this);
        hint.setText(
                weiyun
                        ? "请在下方微云网页用密码或扫码登录。登录后若未自动返回，再点「继续授权」。"
                        : quarkLogin
                                ? "请在夸克中确认授权。如果取消了跳转，可以点「重新打开夸克」。"
                                : "请在下方网页按提示完成登录或授权。完成后若未自动返回，再点「检查登录状态」。");
        hint.setTextSize(14);
        hint.setTextColor(hintColor);
        LinearLayout.LayoutParams hintParams = new LinearLayout.LayoutParams(-1, -2);
        hintParams.topMargin = dp(4);
        header.addView(hint, hintParams);

        Button action = browserButton(actionLabel, hintColor, surface, stroke);
        if (quarkLogin) {
            quarkRetryButton = action;
            action.setEnabled(false);
        }
        action.setOnClickListener(
                view -> {
                    if (weiyun) {
                        loadWeiyunAuthorization();
                    } else if (quarkLogin) {
                        retryQuarkAuthorization();
                    } else {
                        capture();
                        pollRemote();
                    }
                });
        LinearLayout.LayoutParams actionParams = new LinearLayout.LayoutParams(-2, -2);
        actionParams.topMargin = dp(6);
        actionParams.gravity = Gravity.END;
        header.addView(action, actionParams);
        layout.addView(header);

        LinearLayout browser = new LinearLayout(this);
        browser.setOrientation(LinearLayout.VERTICAL);
        browser.setBackground(roundedBackground(mutedSurface, stroke, 12));
        browser.setClipToOutline(true);
        browser.setPadding(dp(1), dp(1), dp(1), dp(1));
        LinearLayout.LayoutParams browserParams = new LinearLayout.LayoutParams(-1, 0, 1);
        browserParams.setMargins(dp(12), 0, dp(12), dp(8));
        layout.addView(browser, browserParams);

        LinearLayout toolbar = new LinearLayout(this);
        toolbar.setGravity(Gravity.CENTER_VERTICAL);
        toolbar.setMinimumHeight(dp(44));
        toolbar.setPadding(dp(12), 0, dp(4), 0);
        TextView browserLabel = new TextView(this);
        browserLabel.setText("内置浏览器");
        browserLabel.setTextSize(13);
        browserLabel.setTextColor(hintColor);
        browserLabel.setTypeface(null, Typeface.BOLD);
        Drawable compass = getDrawable(android.R.drawable.ic_menu_compass).mutate();
        compass.setTint(hintColor);
        compass.setBounds(0, 0, dp(18), dp(18));
        browserLabel.setCompoundDrawablesRelative(compass, null, null, null);
        browserLabel.setCompoundDrawablePadding(dp(6));
        toolbar.addView(browserLabel, new LinearLayout.LayoutParams(0, -2, 1));

        browser.addView(toolbar);
        browser.addView(content, new LinearLayout.LayoutParams(-1, 0, 1));
    }

    private void loadWeiyunAuthorization() {
        // The desktop authorization page exposes Tencent's password and QR login flows.
        web.getSettings()
                .setUserAgentString(
                        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like"
                            + " Gecko) Chrome/130.0.0.0 Safari/537.36");
        web.loadUrl("https://www.weiyun.com/authorize/token?code=" + weiyunCode);
    }

    private Button browserButton(String label, int textColor, int fill, int stroke) {
        Button button = new Button(this);
        button.setText(label);
        button.setTextSize(14);
        button.setTextColor(textColor);
        button.setAllCaps(false);
        button.setMinWidth(dp(48));
        button.setMinimumWidth(dp(48));
        button.setMinHeight(dp(48));
        button.setMinimumHeight(dp(48));
        button.setPadding(dp(12), dp(4), dp(12), dp(4));
        int ripple = (textColor & 0x00ffffff) | 0x24000000;
        button.setBackground(
                new RippleDrawable(
                        ColorStateList.valueOf(ripple), roundedBackground(fill, stroke, 8), null));
        button.setStateListAnimator(null);
        return button;
    }

    private GradientDrawable roundedBackground(int fill, int stroke, int radius) {
        GradientDrawable background = new GradientDrawable();
        background.setColor(fill);
        background.setCornerRadius(dp(radius));
        if (stroke != 0) background.setStroke(dp(1), stroke);
        return background;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private WebView makeWeb() {
        WebView view = new WebView(this);
        WebSettings settings = view.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setUseWideViewPort(true);
        settings.setLoadWithOverviewMode(true);
        // Android tablets omit the Mobile token. Request the phone login flow
        // for these services instead of a desktop form or scan-only entry.
        if ("mobile139".equals(provider) || "ali".equals(provider)) {
            settings.setUserAgentString(mobileAgent(settings.getUserAgentString()));
        }
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        settings.setSupportMultipleWindows(true);
        CookieManager.getInstance().setAcceptThirdPartyCookies(view, true);
        view.setWebViewClient(
                new WebViewClient() {
                    @Override
                    public boolean shouldOverrideUrlLoading(
                            WebView current, WebResourceRequest request) {
                        Uri uri = request.getUrl();
                        if ("https".equals(uri.getScheme())) return false;
                        return handoff(current, uri);
                    }

                    @Override
                    public boolean shouldOverrideUrlLoading(WebView current, String address) {
                        Uri uri = Uri.parse(address);
                        return !"https".equals(uri.getScheme()) && handoff(current, uri);
                    }

                    @Override
                    public void onPageFinished(WebView current, String url) {
                        if (!completed) {
                            captureFrom(current);
                        }
                    }

                    @Override
                    public void onReceivedError(
                            WebView current, WebResourceRequest request, WebResourceError error) {
                        if (request.isForMainFrame()) {
                            toast("官方登录页加载失败，请检查网络后重试");
                        }
                    }

                    @Override
                    public WebResourceResponse shouldInterceptRequest(
                            WebView current, WebResourceRequest request) {
                        if ("mobile139".equals(provider)
                                && official(request.getUrl().getHost(), "139.com", "10086.cn")) {
                            for (Map.Entry<String, String> header :
                                    request.getRequestHeaders().entrySet()) {
                                String value = header.getValue();
                                if ("Authorization".equalsIgnoreCase(header.getKey())
                                        && value != null
                                        && value.startsWith("Basic ")
                                        && value.length() < 32768) {
                                    verifyCandidate(value);
                                    break;
                                }
                            }
                        }
                        return null;
                    }
                });
        view.setWebChromeClient(
                new WebChromeClient() {
                    @Override
                    public boolean onCreateWindow(
                            WebView source, boolean dialog, boolean gesture, Message result) {
                        if (!gesture) return false;
                        WebView child = makeWeb();
                        child.getSettings()
                                .setUserAgentString(source.getSettings().getUserAgentString());
                        String opener =
                                source.getUrl() == null
                                        ? null
                                        : Uri.parse(source.getUrl()).getHost();
                        if (official(
                                opener,
                                "weiyun.com",
                                "qq.com",
                                "weixin.qq.com",
                                "quark.cn",
                                "alipan.com",
                                "aliyundrive.com")) popupOrigins.put(child, opener);
                        content.addView(child, new FrameLayout.LayoutParams(-1, -1));
                        web = child;
                        ((WebView.WebViewTransport) result.obj).setWebView(child);
                        result.sendToTarget();
                        return true;
                    }

                    @Override
                    public void onCloseWindow(WebView child) {
                        content.removeView(child);
                        child.destroy();
                        if (content.getChildCount() > 0)
                            web = (WebView) content.getChildAt(content.getChildCount() - 1);
                    }
                });
        return view;
    }

    private static String mobileAgent(String agent) {
        return agent.contains("Mobile") ? agent : agent.replace(" Safari/", " Mobile Safari/");
    }

    private static boolean official(String host, String... roots) {
        if (host == null) return false;
        for (String root : roots) if (host.equals(root) || host.endsWith("." + root)) return true;
        return false;
    }

    private void retryQuarkAuthorization() {
        if (completed || quarkAuthorizationIntent == null || !hasWindowFocus()) return;
        try {
            startActivity(quarkAuthorizationIntent);
        } catch (ActivityNotFoundException | SecurityException error) {
            toast("未能打开夸克，请确认夸克已安装");
        }
    }

    private boolean handoff(WebView current, Uri uri) {
        boolean quarkLogin = "quark".equals(provider);
        // One authorization page can request a handoff more than once while the system dialog is
        // open.
        if (quarkLogin && (completed || quarkAuthorizationIntent != null)) return true;
        String scheme = uri.getScheme() == null ? "" : uri.getScheme().toLowerCase(Locale.ROOT);
        String host = current.getUrl() == null ? null : Uri.parse(current.getUrl()).getHost();
        if (host == null) host = popupOrigins.get(current);
        if (!official(
                host,
                "weiyun.com",
                "qq.com",
                "weixin.qq.com",
                "quark.cn",
                "alipan.com",
                "aliyundrive.com")) return true;
        if (!Arrays.asList(
                        "intent",
                        "quark",
                        "uclink",
                        "qklink",
                        "ucweb",
                        "mqq",
                        "mqqapi",
                        "mqqopensdkapi",
                        "wtloginmqq",
                        "weixin",
                        "alipans",
                        "aliyundrive")
                .contains(scheme)) return true;
        try {
            Intent out =
                    "intent".equals(scheme)
                            ? Intent.parseUri(uri.toString(), Intent.URI_INTENT_SCHEME)
                            : new Intent(Intent.ACTION_VIEW, uri);
            out.setComponent(null);
            out.setSelector(null);
            out.setFlags(0);
            out.addCategory(Intent.CATEGORY_BROWSABLE);
            String target = out.getPackage();
            if (target != null
                    && !(target.equals("com.tencent.mm")
                            || target.equals("com.tencent.mobileqq")
                            || target.equals("com.quark.browser")
                            || target.equals("com.quark.clouddrive")
                            || target.startsWith("com.alicloud.")
                            || target.startsWith("com.aliyun."))) return true;
            if (Arrays.asList("uclink", "qklink", "ucweb", "quark").contains(scheme))
                out.setPackage("com.quark.browser");
            if ("weixin".equals(scheme)) out.setPackage("com.tencent.mm");
            if (Arrays.asList("mqq", "mqqapi", "mqqopensdkapi", "wtloginmqq").contains(scheme))
                out.setPackage("com.tencent.mobileqq");
            startActivity(out);
            if (quarkLogin) {
                quarkAuthorizationIntent = out;
                quarkRetryButton.setEnabled(true);
            }
        } catch (Exception ignored) {
            toast("未能拉起官方客户端，可继续使用官方网页入口");
        }
        return true;
    }

    private void capture() {
        if (!completed && web != null) captureFrom(web);
    }

    private void captureFrom(WebView current) {
        if (completed || current.getUrl() == null) return;
        Uri uri = Uri.parse(current.getUrl());
        if (!"https".equals(uri.getScheme())) return;
        if ("ali".equals(provider) && "www.alipan.com".equals(uri.getHost())) {
            current.evaluateJavascript(
                    "(function(){try{return"
                        + " sessionStorage.getItem('token')||localStorage.getItem('token')||'';}catch(e){return"
                        + " '';}})()",
                    raw -> {
                        try {
                            Object value = new JSONTokener(raw).nextValue();
                            if (!(value instanceof String)) return;
                            JSONObject token = new JSONObject((String) value);
                            if (!token.optString("access_token").isEmpty())
                                finishToken(token.toString());
                        } catch (Exception ignored) {
                        }
                    });
        }
        if ("tianyi".equals(provider) && "h5.cloud.189.cn".equals(uri.getHost())) {
            String query = uri.getQueryParameter("accessToken");
            if (query != null && !query.isEmpty()) verifyCandidate(query);
            current.evaluateJavascript(
                    "(function(){try{var t=localStorage.getItem('accessToken')||'';try{var"
                        + " p=JSON.parse(t);if(typeof p==='string')t=p;}catch(e){}return"
                        + " t;}catch(e){return '';}})()",
                    raw -> {
                        try {
                            Object value = new JSONTokener(raw).nextValue();
                            if (value instanceof String && !((String) value).isEmpty())
                                verifyCandidate((String) value);
                        } catch (Exception ignored) {
                        }
                    });
        }
        if ("mobile139".equals(provider) && official(uri.getHost(), "yun.139.com")) {
            // Some Android WebViews omit Authorization from intercepted XHR
            // requests. The official mobile page also keeps the same grant in
            // its own authorization cookie, so polling works after login and
            // after reopening an existing official web session.
            String cookies = CookieManager.getInstance().getCookie(current.getUrl());
            if (cookies != null)
                for (String entry : cookies.split(";")) {
                    int at = entry.indexOf('=');
                    if (at < 0 || !"authorization".equals(entry.substring(0, at).trim())) continue;
                    String candidate = Uri.decode(entry.substring(at + 1).trim());
                    if (candidate.startsWith("Basic ")) verifyCandidate(candidate);
                }
        }
    }

    private synchronized void verifyCandidate(String value) {
        if (completed || value.equals(lastCandidate) || value.length() > 32768) return;
        lastCandidate = value;
        worker.execute(
                () -> {
                    try {
                        CloudDrive drive =
                                "tianyi".equals(provider)
                                        ? new TianyiCloudDrive(value)
                                        : new MobileCloudDrive(value);
                        drive.authenticate(false);
                        if (drive instanceof TianyiCloudDrive)
                            ((TianyiCloudDrive) drive).listFolder("-11");
                        else ((MobileCloudDrive) drive).listFolder("/");
                        String token = drive.credentials.toString();
                        handler.post(() -> finishToken(token));
                    } catch (Exception error) {

                        synchronized (CloudLoginActivity.this) {
                            lastCandidate = "";
                        }
                    }
                });
    }

    private void pollRemote() {
        if (completed || pollBusy) return;
        if ("quark".equals(provider) && quark != null && !quarkPage.isEmpty()) {
            pollBusy = true;
            worker.execute(
                    () -> {
                        try {
                            if (quark.pollLogin(quarkPage))
                                handler.post(() -> finishToken(quark.credentials.toString()));
                        } catch (Exception ignored) {
                        } finally {
                            pollBusy = false;
                        }
                    });
        }
        if ("weiyun".equals(provider) && !weiyunCode.isEmpty()) {
            pollBusy = true;
            worker.execute(
                    () -> {
                        try {
                            CloudNet.Response response =
                                    CloudNet.request(
                                            "POST",
                                            "https://www.weiyun.com/api/v3/mcp/token/code",
                                            CloudNet.headers("Content-Type", "application/json"),
                                            CloudDrive.bytes(
                                                    CloudDrive.obj("code", weiyunCode).toString()),
                                            65536);
                            String token = new JSONObject(response.text()).optString("token");
                            if (!token.isEmpty()) handler.post(() -> finishToken(token));
                        } catch (Exception ignored) {
                        } finally {
                            pollBusy = false;
                        }
                    });
        }
    }

    private void toast(String text) {
        if (!completed) Toast.makeText(this, text, Toast.LENGTH_LONG).show();
    }

    private void finishToken(String token) {
        if (completed) return;
        completed = true;
        CookieManager.getInstance().flush();
        setResult(RESULT_OK, new Intent().putExtra("token", token));
        finish();
    }

    @Override
    protected void onDestroy() {
        completed = true;
        handler.removeCallbacks(poll);
        worker.shutdownNow();
        if (content != null)
            for (int i = 0; i < content.getChildCount(); i++) {
                WebView view = (WebView) content.getChildAt(i);
                view.stopLoading();
                view.destroy();
            }
        web = null;
        super.onDestroy();
    }
}
