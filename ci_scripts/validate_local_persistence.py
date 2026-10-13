#!/usr/bin/env python3
"""Reject remote persistence and implicit SwiftData defaults before building."""

from pathlib import Path
import plistlib
import re
import sys


def swift_code(source: str) -> str:
    """Mask comments and string literals while preserving diagnostic offsets."""
    result = list(source)
    position = 0
    string_start = re.compile(r'(#+)?("""|")')
    while position < len(source):
        end = position
        if source.startswith("//", position):
            end = source.find("\n", position)
            if end < 0:
                end = len(source)
        elif source.startswith("/*", position):
            end = position + 2
            depth = 1
            while end < len(source) and depth:
                if source.startswith("/*", end):
                    depth += 1
                    end += 2
                elif source.startswith("*/", end):
                    depth -= 1
                    end += 2
                else:
                    end += 1
        else:
            opening = string_start.match(source, position)
            if opening:
                hashes = opening.group(1) or ""
                closing = opening.group(2) + hashes
                end = position + len(opening.group())
                while end < len(source):
                    if source.startswith("\\" + hashes, end):
                        end += len(hashes) + 2
                    elif source.startswith(closing, end):
                        end += len(closing)
                        break
                    else:
                        end += 1
        if end > position:
            for index in range(position, min(end, len(source))):
                if source[index] != "\n":
                    result[index] = " "
            position = end
        else:
            position += 1
    return "".join(result)


def constructor_arguments(code: str, type_name: str):
    """Yield top-level arguments of balanced constructor calls."""
    pattern = re.compile(r"\b" + type_name + r"\s*(?:\.\s*init\s*)?\(")
    for match in pattern.finditer(code):
        stack = ["("]
        start = position = match.end()
        arguments = []
        while position < len(code) and stack:
            token = code[position]
            if token in "([{":
                stack.append(token)
            elif token in ")]}":
                stack.pop()
                if not stack:
                    arguments.append(code[start:position].strip())
                    break
            elif token == "," and len(stack) == 1:
                arguments.append(code[start:position].strip())
                start = position + 1
            position += 1
        yield match.start(), arguments


def validate(repo_root: Path) -> list[str]:
    """Validate app, test, entitlement, and launch configuration without a network."""
    failures = []
    forbidden_runtime = re.compile(
        r"\bimport\s+CloudKit\b|\bNSUbiquitous[A-Za-z0-9_]*\b|"
        r"\bNSPersistentCloudKitContainer\b|\bCK(?:Container|Database|SyncEngine)\b|"
        r"\b(?:ubiquityIdentityToken|isUbiquitousItem|startDownloadingUbiquitousItem)\b|"
        r"\b(?:registerForRemoteNotifications|didRegisterForRemoteNotificationsWithDeviceToken|"
        r"didReceiveRemoteNotification)\b|\burl\s*\(\s*forUbiquityContainerIdentifier\s*:|"
        r"\bsetUbiquitous\s*\("
    )
    source_roots = ["Pawtrackr", "PawtrackrTests", "PawtrackrUITests", "QualityControl"]
    for root in source_roots:
        for path in sorted((repo_root / root).rglob("*.swift")):
            source = path.read_text()
            code = swift_code(source)
            relative = path.relative_to(repo_root)
            if root == "Pawtrackr":
                for match in re.finditer(r"\bSchemaMigrationPlan\b|\bmigrationPlan\s*:", code):
                    line = source.count("\n", 0, match.start()) + 1
                    failures.append(f"{relative}:{line}: staged migration plans are forbidden (ADR-0004)")
                for offset, arguments in constructor_arguments(code, "Attribute"):
                    if any(re.search(r"\.\s*unique\b", argument) for argument in arguments):
                        line = source.count("\n", 0, offset) + 1
                        failures.append(f"{relative}:{line}: unique constraints are forbidden on store models")
                for match in re.finditer(r"#\s*Unique\s*[<(]", code):
                    line = source.count("\n", 0, match.start()) + 1
                    failures.append(f"{relative}:{line}: unique constraints are forbidden on store models")
            for match in forbidden_runtime.finditer(code):
                line = source.count("\n", 0, match.start()) + 1
                failures.append(f"{relative}:{line}: remote persistence or push API is forbidden")
            for offset, arguments in constructor_arguments(code, "ModelConfiguration"):
                local_argument = any(
                    re.fullmatch(r"cloudKitDatabase\s*:\s*\.\s*none", argument)
                    for argument in arguments
                )
                if not local_argument:
                    line = source.count("\n", 0, offset) + 1
                    failures.append(
                        f"{relative}:{line}: ModelConfiguration must explicitly use cloudKitDatabase: .none "
                        "(or use LocalStoreConfiguration.make)"
                    )
            for offset, arguments in constructor_arguments(code, "ModelContainer"):
                if not any(re.match(r"configurations\s*:", argument) for argument in arguments):
                    line = source.count("\n", 0, offset) + 1
                    failures.append(f"{relative}:{line}: ModelContainer requires explicit local configurations")

    for path in sorted((repo_root / "Pawtrackr").rglob("*.entitlements")):
        values = plistlib.loads(path.read_bytes())
        for key in values:
            if "icloud" in key.lower() or "ubiquity" in key.lower() or "aps-environment" in key.lower():
                failures.append(f"{path.relative_to(repo_root)}: forbidden entitlement {key}")

    info_files = set(repo_root.glob("*Info.plist")) | set((repo_root / "Pawtrackr").rglob("*Info.plist"))
    for path in sorted(info_files):
        if "remote-notification" in plistlib.loads(path.read_bytes()).get("UIBackgroundModes", []):
            failures.append(f"{path.relative_to(repo_root)}: remote-notification background mode is forbidden")

    project_file = repo_root / "Pawtrackr.xcodeproj/project.pbxproj"
    if project_file.exists():
        project = project_file.read_text()
        if "CloudKit.framework" in project or "remote-notification" in project:
            failures.append("Pawtrackr.xcodeproj/project.pbxproj: cloud framework or push background mode is forbidden")
        if re.search(r'"?com\.apple\.(?:iCloud|Push)"?\s*=\s*\{\s*enabled\s*=\s*1', project):
            failures.append("Pawtrackr.xcodeproj/project.pbxproj: cloud or push capability is enabled")
    return failures


if __name__ == "__main__":
    repository = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    errors = validate(repository)
    if errors:
        for error in errors:
            print("Build failed: " + error)
        sys.exit(1)
    print("Local persistence configuration and entitlement gates passed")
