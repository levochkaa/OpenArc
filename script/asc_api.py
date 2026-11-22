#!/usr/bin/env python3
"""Minimal App Store Connect API client for the iOS TestFlight flow.

Credentials come only from the environment:
  OPENARC_ASC_KEY_ID, OPENARC_ASC_ISSUER_ID, OPENARC_ASC_KEY_PATH (.p8).

The ES256 token is signed with the `openssl` CLI, so no third-party Python
packages are needed. Run with `python3 -I`.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API_ROOT = "https://api.appstoreconnect.apple.com"


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def der_to_raw_signature(der: bytes) -> bytes:
    """Converts an ECDSA DER signature to the JOSE r||s form."""
    if len(der) < 8 or der[0] != 0x30:
        fail("unexpected ECDSA signature encoding from openssl")
    index = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    parts = []
    for _ in range(2):
        if der[index] != 0x02:
            fail("unexpected ECDSA signature encoding from openssl")
        length = der[index + 1]
        value = der[index + 2 : index + 2 + length]
        parts.append(value.lstrip(b"\x00").rjust(32, b"\x00"))
        index += 2 + length
    return parts[0] + parts[1]


_token_cache: tuple[str, float] | None = None


def token() -> str:
    global _token_cache
    now = time.time()
    if _token_cache and _token_cache[1] - 60 > now:
        return _token_cache[0]
    key_id = os.environ.get("OPENARC_ASC_KEY_ID", "")
    issuer = os.environ.get("OPENARC_ASC_ISSUER_ID", "")
    key_path = os.environ.get("OPENARC_ASC_KEY_PATH", "")
    if not key_id or not issuer or not key_path:
        fail("set OPENARC_ASC_KEY_ID, OPENARC_ASC_ISSUER_ID and OPENARC_ASC_KEY_PATH")
    if not os.path.isfile(key_path):
        fail("OPENARC_ASC_KEY_PATH does not point to a file")
    expires = int(now) + 15 * 60
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    claims = {"iss": issuer, "iat": int(now), "exp": expires, "aud": "appstoreconnect-v1"}
    signing_input = (
        b64url(json.dumps(header, separators=(",", ":")).encode())
        + "."
        + b64url(json.dumps(claims, separators=(",", ":")).encode())
    )
    result = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path],
        input=signing_input.encode(),
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        fail("openssl could not sign the API token")
    jwt = signing_input + "." + b64url(der_to_raw_signature(result.stdout))
    _token_cache = (jwt, float(expires))
    return jwt


def request(method: str, path: str, query: dict | None = None, body: dict | None = None) -> dict:
    url = path if path.startswith("http") else API_ROOT + path
    if query:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(query)
    global _token_cache
    data = json.dumps(body).encode() if body is not None else None
    for attempt in range(4):
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", "Bearer " + token())
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=60) as response:
                raw = response.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            raw = error.read().decode(errors="replace")
            # App Store Connect now and then rejects a valid token; sign a new one.
            if error.code == 401 and attempt < 3:
                _token_cache = None
                time.sleep(5)
                continue
            if error.code in (429, 500, 502, 503, 504) and attempt < 3:
                time.sleep(5 * (attempt + 1))
                continue
            raise ApiError(error.code, method, path, raw) from None
        except urllib.error.URLError:
            if attempt < 3:
                time.sleep(5 * (attempt + 1))
                continue
            raise
    return {}


class ApiError(Exception):
    def __init__(self, status: int, method: str, path: str, body: str):
        self.status = status
        detail = body
        try:
            errors = json.loads(body).get("errors", [])
            detail = "; ".join(f"{e.get('title')}: {e.get('detail')}" for e in errors) or body
        except (ValueError, AttributeError):
            pass
        super().__init__(f"{method} {path} -> HTTP {status}: {detail}")


def get_all(path: str, query: dict | None = None) -> list[dict]:
    items: list[dict] = []
    query = dict(query or {})
    query.setdefault("limit", "200")
    page = request("GET", path, query)
    while True:
        items.extend(page.get("data", []))
        next_url = page.get("links", {}).get("next")
        if not next_url:
            return items
        page = request("GET", next_url)


# MARK: - Lookups


def find_bundle_id(identifier: str) -> dict | None:
    for item in get_all("/v1/bundleIds", {"filter[identifier]": identifier}):
        if item["attributes"]["identifier"] == identifier:
            return item
    return None


def find_app(bundle_id: str) -> dict | None:
    apps = get_all("/v1/apps", {"filter[bundleId]": bundle_id})
    for app in apps:
        if app["attributes"]["bundleId"] == bundle_id:
            return app
    return None


def require_app(bundle_id: str) -> dict:
    app = find_app(bundle_id)
    if app is None:
        fail(
            f"App Store Connect has no app record for {bundle_id}. "
            "Create it in App Store Connect > Apps > New App (see docs/ios-testflight.md)."
        )
    return app


def latest_build_number(app_id: str, version: str | None) -> int:
    query = {"filter[app]": app_id, "filter[preReleaseVersion.platform]": "IOS", "limit": "200"}
    if version:
        query["filter[preReleaseVersion.version]"] = version
    highest = 0
    for build in get_all("/v1/builds", query):
        try:
            highest = max(highest, int(build["attributes"]["version"]))
        except (KeyError, ValueError):
            continue
    return highest


# MARK: - Commands


def cmd_get(args: argparse.Namespace) -> None:
    query = dict(pair.split("=", 1) for pair in args.query)
    if args.all:
        print(json.dumps(get_all(args.path, query), indent=2))
    else:
        print(json.dumps(request("GET", args.path, query), indent=2))


def read_body(source: str) -> dict:
    """A JSON request body: inline, `@file`, or `-` for stdin."""
    if source == "-":
        return json.load(sys.stdin)
    if source.startswith("@"):
        with open(source[1:], encoding="utf-8") as handle:
            return json.load(handle)
    return json.loads(source)


def cmd_write(args: argparse.Namespace) -> None:
    print(json.dumps(request(args.method, args.path, body=read_body(args.body)), indent=2))


def cmd_team_id(args: argparse.Namespace) -> None:
    bundle = find_bundle_id(args.bundle_id)
    if bundle is None:
        fail(f"no bundle ID {args.bundle_id} on the developer portal")
    print(bundle["attributes"]["seedId"])


def cmd_app_id(args: argparse.Namespace) -> None:
    print(require_app(args.bundle_id)["id"])


def cmd_next_build_number(args: argparse.Namespace) -> None:
    app = require_app(args.bundle_id)
    # Build numbers must grow across every iOS version, so take the highest of all builds.
    print(max(latest_build_number(app["id"], None), args.minimum - 1) + 1)


def find_build(app_id: str, version: str, build_number: str) -> dict | None:
    builds = get_all(
        "/v1/builds",
        {
            "filter[app]": app_id,
            "filter[version]": build_number,
            "filter[preReleaseVersion.version]": version,
            "filter[preReleaseVersion.platform]": "IOS",
        },
    )
    return builds[0] if builds else None


def upload_errors(app_id: str, version: str, build_number: str) -> None:
    """Stops with App Store Connect's reasons when it refused an upload before making a build."""
    for upload in get_all(f"/v1/apps/{app_id}/buildUploads"):
        attributes = upload["attributes"]
        if attributes.get("cfBundleShortVersionString") != version or attributes.get("cfBundleVersion") != build_number:
            continue
        state = attributes.get("state") or {}
        if state.get("state") == "FAILED" or state.get("errors"):
            reasons = "; ".join(
                f"{error.get('code')}: {error.get('description') or error.get('message')}"
                for error in state.get("errors", [])
            )
            fail(f"App Store Connect refused upload {version} ({build_number}): {reasons or state}")


def cmd_wait_build(args: argparse.Namespace) -> None:
    app = require_app(args.bundle_id)
    deadline = time.time() + args.timeout
    build = None
    last_state = None
    while time.time() < deadline:
        build = find_build(app["id"], args.version, args.build_number)
        state = build["attributes"]["processingState"] if build else "NOT_YET_VISIBLE"
        if state != last_state:
            print(f"build {args.version} ({args.build_number}): {state}", file=sys.stderr)
            last_state = state
        if state == "VALID":
            break
        if state in ("FAILED", "INVALID"):
            fail(f"App Store Connect rejected build {args.build_number}: {state}")
        if build is None:
            upload_errors(app["id"], args.version, args.build_number)
        time.sleep(30)
    else:
        fail(f"build {args.build_number} did not finish processing in {args.timeout} s")

    assert build is not None
    if build["attributes"].get("usesNonExemptEncryption") is None:
        # Info.plist answers export compliance; this covers builds that predate the key.
        try:
            request(
                "PATCH",
                f"/v1/builds/{build['id']}",
                body={
                    "data": {
                        "type": "builds",
                        "id": build["id"],
                        "attributes": {"usesNonExemptEncryption": False},
                    }
                },
            )
        except ApiError as error:
            print(f"warning: could not set export compliance: {error}", file=sys.stderr)
    print(build["id"])


def find_or_create_internal_group(app_id: str, name: str) -> dict:
    for group in get_all(f"/v1/apps/{app_id}/betaGroups"):
        if group["attributes"]["name"] == name:
            return group
    created = request(
        "POST",
        "/v1/betaGroups",
        body={
            "data": {
                "type": "betaGroups",
                "attributes": {"name": name, "isInternalGroup": True, "hasAccessToAllBuilds": False},
                "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
            }
        },
    )
    print(f"created internal TestFlight group {name}", file=sys.stderr)
    return created["data"]


def ensure_testers(app_id: str, group: dict, emails: list[str]) -> None:
    if not emails:
        return
    existing = {
        tester["attributes"].get("email", "").lower()
        for tester in get_all(f"/v1/betaGroups/{group['id']}/betaTesters")
    }
    users = get_all("/v1/users")
    for email in emails:
        if email.lower() in existing:
            continue
        user = next((u for u in users if u["attributes"].get("username", "").lower() == email.lower()), None)
        if user is None:
            print(f"warning: {email} is not a member of the App Store Connect team", file=sys.stderr)
            continue
        attributes = user["attributes"]
        request(
            "POST",
            "/v1/betaTesters",
            body={
                "data": {
                    "type": "betaTesters",
                    "attributes": {
                        "email": attributes["username"],
                        "firstName": attributes.get("firstName", ""),
                        "lastName": attributes.get("lastName", ""),
                    },
                    "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": group["id"]}]}},
                }
            },
        )
        print(f"added {email} to TestFlight group {group['attributes']['name']}", file=sys.stderr)


def cmd_ensure_group(args: argparse.Namespace) -> None:
    app = require_app(args.bundle_id)
    group = find_or_create_internal_group(app["id"], args.group)
    emails = list(args.tester)
    if args.all_admins:
        emails += [
            user["attributes"]["username"]
            for user in get_all("/v1/users")
            if {"ADMIN", "ACCOUNT_HOLDER"} & set(user["attributes"].get("roles", []))
        ]
    ensure_testers(app["id"], group, sorted(set(emails)))
    print(group["id"])


def cmd_add_build_to_group(args: argparse.Namespace) -> None:
    app = require_app(args.bundle_id)
    group = find_or_create_internal_group(app["id"], args.group)
    try:
        request(
            "POST",
            f"/v1/betaGroups/{group['id']}/relationships/builds",
            body={"data": [{"type": "builds", "id": args.build_id}]},
        )
    except ApiError as error:
        # Internal groups with access to all builds reject explicit assignment.
        if error.status != 409 and error.status != 422:
            raise
        print(f"note: {error}", file=sys.stderr)
    print(f"build is in TestFlight group {args.group}", file=sys.stderr)


BETA_DESCRIPTION = (
    "OpenArc is a web browser for iPhone and iPad. Type an address or a search in the field that opens on launch; "
    "pages open in tabs grouped into Spaces. Signing in is optional and syncs Spaces and tabs with OpenArc for Mac."
)


def ensure_beta_test_information(app_id: str, feedback_email: str) -> None:
    """Fills the Test Information page and the Beta App Review contact, which external testing needs."""
    localizations = get_all(f"/v1/apps/{app_id}/betaAppLocalizations")
    attributes = {
        "description": BETA_DESCRIPTION,
        "feedbackEmail": feedback_email,
        "marketingUrl": "https://openarc.su",
        "privacyPolicyUrl": "https://openarc.su/privacy/",
    }
    if localizations:
        for localization in localizations:
            missing = {key: value for key, value in attributes.items() if not localization["attributes"].get(key)}
            if missing:
                request(
                    "PATCH",
                    f"/v1/betaAppLocalizations/{localization['id']}",
                    body={"data": {"type": "betaAppLocalizations", "id": localization["id"], "attributes": missing}},
                )
    else:
        request(
            "POST",
            "/v1/betaAppLocalizations",
            body={
                "data": {
                    "type": "betaAppLocalizations",
                    "attributes": {"locale": "en-US", **attributes},
                    "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
                }
            },
        )

    detail = request("GET", f"/v1/apps/{app_id}/betaAppReviewDetail")["data"]
    if detail["attributes"].get("contactEmail"):
        return
    # The App Store review contact and notes already describe how to review the app.
    store_detail = None
    for version in get_all(f"/v1/apps/{app_id}/appStoreVersions"):
        try:
            store_detail = request("GET", f"/v1/appStoreVersions/{version['id']}/appStoreReviewDetail")["data"]
        except ApiError:
            continue
        if store_detail and store_detail["attributes"].get("contactEmail"):
            break
    if not store_detail or not store_detail["attributes"].get("contactEmail"):
        fail("set the App Review contact in App Store Connect first; Beta App Review needs one")
    keys = ["contactFirstName", "contactLastName", "contactPhone", "contactEmail", "notes"]
    review = {key: store_detail["attributes"].get(key) for key in keys}
    review["demoAccountRequired"] = False
    request(
        "PATCH",
        f"/v1/betaAppReviewDetails/{detail['id']}",
        body={"data": {"type": "betaAppReviewDetails", "id": detail["id"], "attributes": review}},
    )


def find_or_create_external_group(app_id: str, name: str) -> dict:
    for group in get_all(f"/v1/apps/{app_id}/betaGroups"):
        if group["attributes"]["name"] == name:
            if group["attributes"].get("isInternalGroup"):
                fail(f"TestFlight group {name} is internal")
            return group
    created = request(
        "POST",
        "/v1/betaGroups",
        body={
            "data": {
                "type": "betaGroups",
                "attributes": {
                    "name": name,
                    "isInternalGroup": False,
                    "publicLinkEnabled": True,
                    "publicLinkLimitEnabled": False,
                    "feedbackEnabled": True,
                },
                "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
            }
        },
    )
    print(f"created external TestFlight group {name} with a public link", file=sys.stderr)
    return created["data"]


def cmd_external_build(args: argparse.Namespace) -> None:
    app = require_app(args.bundle_id)
    ensure_beta_test_information(app["id"], args.feedback_email)
    build_id = args.build_id
    if args.whats_new:
        localizations = get_all(f"/v1/builds/{build_id}/betaBuildLocalizations")
        if localizations:
            request(
                "PATCH",
                f"/v1/betaBuildLocalizations/{localizations[0]['id']}",
                body={
                    "data": {
                        "type": "betaBuildLocalizations",
                        "id": localizations[0]["id"],
                        "attributes": {"whatsNew": args.whats_new},
                    }
                },
            )
        else:
            request(
                "POST",
                "/v1/betaBuildLocalizations",
                body={
                    "data": {
                        "type": "betaBuildLocalizations",
                        "attributes": {"locale": "en-US", "whatsNew": args.whats_new},
                        "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
                    }
                },
            )
    group = find_or_create_external_group(app["id"], args.group)
    request(
        "POST",
        f"/v1/betaGroups/{group['id']}/relationships/builds",
        body={"data": [{"type": "builds", "id": build_id}]},
    )
    try:
        request(
            "POST",
            "/v1/betaAppReviewSubmissions",
            body={
                "data": {
                    "type": "betaAppReviewSubmissions",
                    "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
                }
            },
        )
        print("submitted the build for Beta App Review", file=sys.stderr)
    except ApiError as error:
        # A build already in review, or a later build of an approved version, needs no submission.
        if error.status != 409 and error.status != 422:
            raise
        print(f"note: {error}", file=sys.stderr)
    group = request("GET", f"/v1/betaGroups/{group['id']}")["data"]
    print(group["attributes"].get("publicLink") or "")


def cmd_build_status(args: argparse.Namespace) -> None:
    app = require_app(args.bundle_id)
    build = find_build(app["id"], args.version, args.build_number)
    if build is None:
        fail("build not found")
    detail = request("GET", f"/v1/builds/{build['id']}/buildBetaDetail")
    groups = [
        group
        for group in get_all(f"/v1/apps/{app['id']}/betaGroups")
        if any(item["id"] == build["id"] for item in get_all(f"/v1/betaGroups/{group['id']}/builds"))
    ]
    print(
        json.dumps(
            {
                "id": build["id"],
                "processingState": build["attributes"].get("processingState"),
                "usesNonExemptEncryption": build["attributes"].get("usesNonExemptEncryption"),
                "expired": build["attributes"].get("expired"),
                "internalBuildState": detail["data"]["attributes"].get("internalBuildState"),
                "externalBuildState": detail["data"]["attributes"].get("externalBuildState"),
                "groups": [group["attributes"]["name"] for group in groups],
            },
            indent=2,
        )
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    get = commands.add_parser("get", help="GET an API path and print the JSON")
    get.add_argument("path")
    get.add_argument("query", nargs="*", help="key=value query pairs")
    get.add_argument("--all", action="store_true", help="follow pagination")
    get.set_defaults(func=cmd_get)

    for method in ("PATCH", "POST"):
        write = commands.add_parser(method.lower(), help=f"{method} a JSON body to an API path and print the reply")
        write.add_argument("path")
        write.add_argument("body", help="JSON body, @file, or - for stdin")
        write.set_defaults(func=cmd_write, method=method)

    team = commands.add_parser("team-id", help="print the team ID that owns a bundle ID")
    team.add_argument("bundle_id")
    team.set_defaults(func=cmd_team_id)

    app_id = commands.add_parser("app-id", help="print the App Store Connect app ID")
    app_id.add_argument("bundle_id")
    app_id.set_defaults(func=cmd_app_id)

    next_build = commands.add_parser("next-build-number", help="print the next free iOS build number")
    next_build.add_argument("bundle_id")
    next_build.add_argument("--minimum", type=int, default=1)
    next_build.set_defaults(func=cmd_next_build_number)

    wait = commands.add_parser("wait-build", help="wait until an uploaded build is processed")
    wait.add_argument("bundle_id")
    wait.add_argument("version")
    wait.add_argument("build_number")
    wait.add_argument("--timeout", type=int, default=3600)
    wait.set_defaults(func=cmd_wait_build)

    ensure = commands.add_parser("ensure-group", help="create an internal TestFlight group if missing")
    ensure.add_argument("bundle_id")
    ensure.add_argument("group")
    ensure.add_argument("--tester", action="append", default=[], help="team member email")
    ensure.add_argument("--all-admins", action="store_true", help="add every Admin and Account Holder")
    ensure.set_defaults(func=cmd_ensure_group)

    add = commands.add_parser("add-build-to-group", help="give a TestFlight group a build")
    add.add_argument("bundle_id")
    add.add_argument("group")
    add.add_argument("build_id")
    add.set_defaults(func=cmd_add_build_to_group)

    external = commands.add_parser(
        "external-build", help="give an external TestFlight group with a public link a build and submit it for review"
    )
    external.add_argument("bundle_id")
    external.add_argument("group")
    external.add_argument("build_id")
    external.add_argument("--whats-new", help="What to Test text for the build")
    external.add_argument("--feedback-email", default="support@openarc.su")
    external.set_defaults(func=cmd_external_build)

    status = commands.add_parser("build-status", help="print a build's processing and TestFlight state")
    status.add_argument("bundle_id")
    status.add_argument("version")
    status.add_argument("build_number")
    status.set_defaults(func=cmd_build_status)

    args = parser.parse_args()
    try:
        args.func(args)
    except ApiError as error:
        fail(str(error))


if __name__ == "__main__":
    main()
