#!/usr/bin/env python3
"""Exercise the real release preflight and cleanup against temporary files."""
import os
import plistlib
from pathlib import Path
import subprocess
import tempfile


def executable(path: Path, content: str) -> None:
    path.write_text("#!/bin/bash\n" + content)
    path.chmod(0o755)


def main() -> None:
    source = Path(__file__).with_name("release.sh").read_text()
    passed = 0
    with tempfile.TemporaryDirectory(prefix="mo-release-tests-") as temp:
        root = Path(temp)
        commands = root / "bin"
        commands.mkdir()
        executable(commands / "gh", "exit 0\n")
        executable(commands / "git", 'if [ "$1" = status ]; then exit 0; fi\nexit "${MO_GIT_EXIT:-0}"\n')
        env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"], TMPDIR=temp)
        original = plistlib.dumps({"CFBundleShortVersionString": "2.15.0", "CFBundleVersion": "40", "LocalUncommittedKey": "keep me"})
        for case, test_body, build_body, expected in [
            ("test-failed", "exit 1\n", "exit 0\n", 1),
            ("build-failed", "exit 0\n", "exit 1\n", 1),
            ("terminated", 'kill -TERM "$PPID"\n', "exit 0\n", 143),
        ]:
            workspace = root / case
            workspace.mkdir()
            executable(workspace / "release.sh", source.removeprefix("#!/bin/bash\n"))
            (workspace / "Info.plist").write_bytes(original)
            executable(workspace / "test.sh", test_body)
            executable(workspace / "build.sh", build_body)
            result = subprocess.run(["/bin/bash", "release.sh", "2.15.1"], cwd=workspace, env=env, capture_output=True, text=True, timeout=10)
            assert result.returncode == expected, (case, result.returncode, result.stderr)
            assert (workspace / "Info.plist").read_bytes() == original, case
            passed += 1

        # 复用实际清理代码与提交边界，跳过安装、推送等外部动作。
        preflight = source.split("./test.sh ||", 1)[0]
        commit_boundary = source.split('git commit -qm "v$V" -- Info.plist', 1)[1].split("SHA=", 1)[0]
        for case, commit_exit, should_restore in [("commit-failed", "1", True), ("push-failed-after-commit", "0", False)]:
            workspace = root / case
            workspace.mkdir()
            (workspace / "Info.plist").write_bytes(original)
            script = preflight + 'git commit -qm "v$V" -- Info.plist' + commit_boundary.replace("git push -q origin HEAD", "false")
            (workspace / "release.sh").write_text(script)
            result = subprocess.run(["/bin/bash", "release.sh", "2.15.1"], cwd=workspace, env=dict(env, MO_GIT_EXIT=commit_exit), capture_output=True, text=True, timeout=10)
            assert result.returncode == 1, (case, result.stderr)
            assert ((workspace / "Info.plist").read_bytes() == original) == should_restore, case
            passed += 1
        assert sorted(p.name for p in root.iterdir()) == sorted(["bin", "test-failed", "build-failed", "terminated", "commit-failed", "push-failed-after-commit"]), "临时版本备份没有清理"
    print(f"release-rollback: {passed} 通过, 0 失败")


if __name__ == "__main__":
    main()
