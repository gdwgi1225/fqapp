"""Real-engine unwind and ASan speech lifetime regressions; no audio output."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
engine = Path(os.environ["FLUTTER_ROOT"]) / "bin/cache/artifacts/engine/linux-x64"
source = (root / "native/linux/tts.cc").read_text()
load = "    auto *self = active.load();"
destructor = "  ~Speech() override {"
assert source.count(load) == source.count(destructor) == 1
source = source.replace("class Speech final : public Tts {",
                        "class Speech final : public Tts {\n  friend struct SpeechLifetimeProbe;")
source = source.replace(load, load + "\n    lifetime_after_load();")
source = source.replace(destructor, destructor + "\n    lifetime_destructor_entered();")
source = ("namespace fqapp { void lifetime_after_load(); "
          "void lifetime_destructor_entered(); }\n" + source)
source += (root / "native/tests/linux_tts_lifetime.cc").read_text()
scratch = Path(tempfile.mkdtemp(prefix="fqapp-tts-lifetime-"))
print("evidence=" + str(scratch), flush=True)
(scratch / "probe.cc").write_text(source)
# libspeechd uses the same C cleanup/forced-unwind path when closing its reader.
# ASan preloads runtime dependencies, so exercise this without ASan as well.
subprocess.run(["cc", "-fexceptions", "-pthread",
                str(root / "native/tests/linux_unwind.c"), "-L" + str(engine),
                "-Wl,--push-state,--no-as-needed", "-lgcc_s", "-Wl,--pop-state",
                "-Wl,--no-as-needed", "-lflutter_linux_gtk", "-Wl,--as-needed",
                "-Wl,-rpath," + str(engine), "-o", str(scratch / "unwind")],
               check=True)
subprocess.run([str(scratch / "unwind")], check=True, timeout=10)
print("PASS real-engine pthread cancellation cleanup", flush=True)
flags = shlex.split(subprocess.check_output(
    ["pkg-config", "--cflags", "--libs", "gtk+-3.0", "speech-dispatcher"], text=True))
subprocess.run(["c++", "-std=c++17", "-g", "-O1", "-pthread", "-fsanitize=address",
                "-fno-omit-frame-pointer", "-I" + str(root / "native/linux"),
                "-I" + str(engine), str(scratch / "probe.cc"), "-L" + str(engine),
                "-Wl,--push-state,--no-as-needed", "-lgcc_s", "-Wl,--pop-state",
                "-lflutter_linux_gtk", "-Wl,-rpath," + str(engine), *flags,
                "-o", str(scratch / "probe")], check=True)
with tempfile.TemporaryDirectory(prefix="fqapp-tts-unavailable-") as runtime:
    # libspeechd 0.12.1 leaks its internal spawn_report on connect failure.
    # Keep ASan enabled here and retain leak detection for the lifetime test.
    subprocess.run(
        [str(scratch / "probe"), "unavailable"], check=True, timeout=30,
        env=dict(os.environ, ASAN_OPTIONS="detect_leaks=0:halt_on_error=1",
                 G_DEBUG="fatal-criticals",
                 SPEECHD_ADDRESS="unix_socket:" + runtime + "/speechd.sock"))
subprocess.run([str(scratch / "probe")], check=True, timeout=30,
               env=dict(os.environ, ASAN_OPTIONS="detect_leaks=1:halt_on_error=1",
                        G_DEBUG="fatal-criticals"))
