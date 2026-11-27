#!/usr/bin/env python3
"""
Waits for an uploaded App Store Connect build to finish processing, attaches it to an
External TestFlight group (creating the group with a public link if needed), and submits
it for External Beta App Review.

If this build or another build is already in review / waiting for review, or if Apple
rejects the submission because an in-review build already exists, this script logs a
notice and exits 0 (non-fatal for external TestFlight automation).

Environment variables:
  ASC_KEY_PATH       Path to App Store Connect API .p8 key
  ASC_KEY_ID         Key ID
  ASC_ISSUER         Issuer ID
  ASC_BUNDLE_ID      Bundle identifier (default: ad.neko.arbor)
  APP_VERSION        Marketing version (e.g. 0.4.0)
  BUILD_NUMBER       Build number (e.g. 1)
  TESTFLIGHT_GROUP   External beta group name (default: Public Beta)
  WHATS_NEW          Optional "What to Test" notes (en-US)
  POLL_TIMEOUT_SEC   Max seconds to wait for build processing (default: 900)
"""

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt

API_BASE = "https://api.appstoreconnect.apple.com"


class ASCClient:
    def __init__(self, key_path: str, key_id: str, issuer: str):
        self.key_path = key_path
        self.key_id = key_id
        self.issuer = issuer
        self._priv = open(key_path, "rb").read()
        self._token = None
        self._exp = 0

    def token(self) -> str:
        now = int(time.time())
        if not self._token or now >= self._exp - 60:
            self._exp = now + 900
            self._token = jwt.encode(
                {"iss": self.issuer, "iat": now, "exp": self._exp, "aud": "appstoreconnect-v1"},
                self._priv,
                algorithm="ES256",
                headers={"kid": self.key_id},
            )
        return self._token

    def request(self, method: str, path: str, body=None):
        url = path if path.startswith("http") else API_BASE + path
        data = json.dumps(body).encode("utf-8") if body is not None else None
        req = urllib.request.Request(
            url,
            data=data,
            method=method,
            headers={
                "Authorization": f"Bearer {self.token()}",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                raw = resp.read().decode("utf-8")
                return resp.status, (json.loads(raw) if raw else {})
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8", errors="replace")
            try:
                parsed = json.loads(raw)
            except Exception:
                parsed = {"raw": raw}
            return exc.code, parsed


def is_already_in_review_error(status: int, payload: dict) -> bool:
    if status not in (409, 422):
        return False
    text = json.dumps(payload).lower()
    markers = [
        "already",
        "in_review",
        "in review",
        "waiting_for_review",
        "waiting for review",
        "another build",
        "state_error",
        "cannot be submitted",
        "submission already exists",
        "beta_app_review_submission",
    ]
    return any(m in text for m in markers)


def find_app(asc: ASCClient, bundle_id: str) -> dict:
    q = urllib.parse.quote(bundle_id)
    status, data = asc.request("GET", f"/v1/apps?filter[bundleId]={q}")
    if status != 200 or not data.get("data"):
        raise RuntimeError(f"App not found for bundleId={bundle_id} (status={status}): {data}")
    return data["data"][0]


def wait_for_build(asc: ASCClient, app_id: str, version: str, build_number: str, timeout: int) -> dict:
    deadline = time.time() + timeout
    q_ver = urllib.parse.quote(build_number)
    while True:
        status, data = asc.request(
            "GET",
            f"/v1/builds?filter[app]={app_id}&filter[version]={q_ver}&include=preReleaseVersion,betaAppReviewSubmission&limit=20",
        )
        if status == 200:
            included = {
                (item["type"], item["id"]): item
                for item in data.get("included", [])
            }
            for b in data.get("data", []):
                pre_rel = b.get("relationships", {}).get("preReleaseVersion", {}).get("data")
                pre_ver = None
                if pre_rel:
                    pre_obj = included.get((pre_rel["type"], pre_rel["id"]))
                    pre_ver = pre_obj.get("attributes", {}).get("version") if pre_obj else None
                if version and pre_ver and pre_ver != version:
                    continue
                state = b["attributes"].get("processingState", "")
                print(f"Build {pre_ver or version} ({build_number}) [id={b['id']}]: processingState={state}", flush=True)
                if state == "VALID":
                    return b
                if state in ("INVALID", "FAILED"):
                    raise RuntimeError(f"Build processing failed with state={state}")
        if time.time() >= deadline:
            raise TimeoutError(f"Timed out waiting for build {version} ({build_number}) to become VALID")
        time.sleep(20)


def copy_contact_from_account(asc: ASCClient, current_app_id: str) -> dict:
    """Finds existing beta review contact details from another app on the same ASC account."""
    status, data = asc.request("GET", "/v1/apps?limit=25")
    if status != 200:
        return {}
    for app in data.get("data", []):
        if app["id"] == current_app_id:
            continue
        st, detail = asc.request("GET", f"/v1/apps/{app['id']}/betaAppReviewDetail")
        if st == 200:
            attrs = detail.get("data", {}).get("attributes", {})
            if attrs.get("contactEmail") and attrs.get("contactFirstName") and attrs.get("contactLastName") and attrs.get("contactPhone"):
                return {
                    "contactFirstName": attrs["contactFirstName"],
                    "contactLastName": attrs["contactLastName"],
                    "contactEmail": attrs["contactEmail"],
                    "contactPhone": attrs["contactPhone"],
                }
    return {}


def ensure_beta_app_metadata(asc: ASCClient, app_id: str, description: str, feedback_email: str):
    """Ensures Beta App Description, feedbackEmail, and Beta App Review contact info are set."""
    fallback_contact = {}
    st_det, det_data = asc.request("GET", f"/v1/apps/{app_id}/betaAppReviewDetail")
    if st_det == 200:
        det = det_data["data"]
        attrs = det.get("attributes", {})
        needed = ("contactFirstName", "contactLastName", "contactEmail", "contactPhone")
        if any(not attrs.get(k) for k in needed):
            fallback_contact = copy_contact_from_account(asc, app_id)
            patch = {}
            env_map = {
                "contactFirstName": os.environ.get("BETA_CONTACT_FIRST_NAME", ""),
                "contactLastName": os.environ.get("BETA_CONTACT_LAST_NAME", ""),
                "contactEmail": os.environ.get("BETA_CONTACT_EMAIL", ""),
                "contactPhone": os.environ.get("BETA_CONTACT_PHONE", ""),
            }
            for k in needed:
                val = attrs.get(k) or env_map[k] or fallback_contact.get(k, "")
                if val and not attrs.get(k):
                    patch[k] = val
            if not attrs.get("demoAccountRequired"):
                patch["demoAccountRequired"] = False
            if patch:
                asc.request(
                    "PATCH",
                    f"/v1/betaAppReviewDetails/{det['id']}",
                    {"data": {"type": "betaAppReviewDetails", "id": det["id"], "attributes": patch}},
                )
        if not feedback_email:
            feedback_email = attrs.get("contactEmail") or fallback_contact.get("contactEmail", "")

    status, data = asc.request("GET", f"/v1/apps/{app_id}/betaAppLocalizations")
    existing = {loc["attributes"]["locale"]: loc for loc in data.get("data", [])} if status == 200 else {}
    if "en-US" in existing:
        loc = existing["en-US"]
        attrs = loc.get("attributes", {})
        patch = {}
        if not attrs.get("description"):
            patch["description"] = description
        if feedback_email and not attrs.get("feedbackEmail"):
            patch["feedbackEmail"] = feedback_email
        if patch:
            asc.request(
                "PATCH",
                f"/v1/betaAppLocalizations/{loc['id']}",
                {"data": {"type": "betaAppLocalizations", "id": loc["id"], "attributes": patch}},
            )
    else:
        attrs = {"locale": "en-US", "description": description}
        if feedback_email:
            attrs["feedbackEmail"] = feedback_email
        asc.request(
            "POST",
            "/v1/betaAppLocalizations",
            {
                "data": {
                    "type": "betaAppLocalizations",
                    "attributes": attrs,
                    "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
                }
            },
        )


def ensure_export_compliance_and_notes(asc: ASCClient, build_id: str, whats_new: str):
    # Mark usesNonExemptEncryption=false if needed
    asc.request(
        "PATCH",
        f"/v1/builds/{build_id}",
        {"data": {"type": "builds", "id": build_id, "attributes": {"usesNonExemptEncryption": False}}},
    )
    # Ensure en-US BetaBuildLocalization has "What to Test"
    status, data = asc.request("GET", f"/v1/builds/{build_id}/betaBuildLocalizations")
    existing = {loc["attributes"]["locale"]: loc["id"] for loc in data.get("data", [])} if status == 200 else {}
    if "en-US" in existing:
        asc.request(
            "PATCH",
            f"/v1/betaBuildLocalizations/{existing['en-US']}",
            {"data": {"type": "betaBuildLocalizations", "id": existing["en-US"], "attributes": {"whatsNew": whats_new}}},
        )
    else:
        asc.request(
            "POST",
            "/v1/betaBuildLocalizations",
            {
                "data": {
                    "type": "betaBuildLocalizations",
                    "attributes": {"locale": "en-US", "whatsNew": whats_new},
                    "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
                }
            },
        )


def ensure_external_group(asc: ASCClient, app_id: str, group_name: str) -> dict:
    status, data = asc.request("GET", f"/v1/apps/{app_id}/betaGroups?limit=50")
    if status == 200:
        for g in data.get("data", []):
            attrs = g.get("attributes", {})
            if not attrs.get("isInternalGroup", False) and attrs.get("name") == group_name:
                return g
    status, created = asc.request(
        "POST",
        "/v1/betaGroups",
        {
            "data": {
                "type": "betaGroups",
                "attributes": {
                    "name": group_name,
                    "isInternalGroup": False,
                    "publicLinkEnabled": True,
                    "feedbackEnabled": True,
                },
                "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
            }
        },
    )
    if status not in (200, 201):
        raise RuntimeError(f"Failed to create external beta group '{group_name}' ({status}): {created}")
    return created["data"]


def any_build_in_review(asc: ASCClient, app_id: str) -> str | None:
    status, data = asc.request(
        "GET",
        f"/v1/builds?filter[app]={app_id}&include=betaAppReviewSubmission&sort=-uploadedDate&limit=10",
    )
    if status != 200:
        return None
    for item in data.get("included", []):
        if item.get("type") == "betaAppReviewSubmissions":
            state = item.get("attributes", {}).get("betaReviewState", "")
            if state in ("WAITING_FOR_REVIEW", "IN_REVIEW"):
                return state
    return None


def main() -> int:
    key_path = os.environ["ASC_KEY_PATH"]
    key_id = os.environ["ASC_KEY_ID"]
    issuer = os.environ["ASC_ISSUER"]
    bundle_id = os.environ.get("ASC_BUNDLE_ID", "ad.neko.arbor")
    version = os.environ.get("APP_VERSION", "")
    build_number = os.environ["BUILD_NUMBER"]
    group_name = os.environ.get("TESTFLIGHT_GROUP", "Public Beta")
    whats_new = os.environ.get(
        "WHATS_NEW",
        f"Arbor Files {version} (build {build_number}): Explorer-style file manager for macOS.",
    )
    beta_description = os.environ.get(
        "BETA_APP_DESCRIPTION",
        "Arbor Files is a native macOS file manager that brings the Windows File Explorer experience to Mac — "
        "including folder tree navigation, clickable breadcrumbs, real Cut & Paste, 8 view layouts, collapsible groups, "
        "Details & Preview panes, Spotlight-backed search, and 11 languages.",
    )
    feedback_email = os.environ.get("BETA_FEEDBACK_EMAIL", "")
    timeout = int(os.environ.get("POLL_TIMEOUT_SEC", "900"))

    asc = ASCClient(key_path, key_id, issuer)
    app = find_app(asc, bundle_id)
    app_id = app["id"]
    print(f"App: {app['attributes']['name']} ({bundle_id}, id={app_id})", flush=True)

    build = wait_for_build(asc, app_id, version, build_number, timeout)
    build_id = build["id"]

    ensure_beta_app_metadata(asc, app_id, beta_description, feedback_email)
    ensure_export_compliance_and_notes(asc, build_id, whats_new)

    group = ensure_external_group(asc, app_id, group_name)
    group_id = group["id"]
    public_link = group.get("attributes", {}).get("publicLink")
    print(f"External group: {group_name} (id={group_id}, publicLink={public_link})", flush=True)

    # Attach build to external group (204 on success; 409 if already attached).
    st_add, add_resp = asc.request(
        "POST",
        f"/v1/betaGroups/{group_id}/relationships/builds",
        {"data": [{"type": "builds", "id": build_id}]},
    )
    if st_add in (200, 201, 204):
        print(f"Attached build {build_id} to external group '{group_name}'.", flush=True)
    elif st_add == 409:
        print(f"Build {build_id} is already attached to external group '{group_name}'.", flush=True)
    else:
        print(f"Warning: attaching build to group returned {st_add}: {add_resp}", flush=True)

    # Check if a build is already in review / waiting for review before submitting.
    existing_review = any_build_in_review(asc, app_id)
    if existing_review:
        print(
            f"Notice: An external TestFlight build is already {existing_review}. "
            "Skipping new Beta App Review submission (non-fatal).",
            flush=True,
        )
        return 0

    # Submit build for External Beta App Review.
    st_sub, sub_resp = asc.request(
        "POST",
        "/v1/betaAppReviewSubmissions",
        {
            "data": {
                "type": "betaAppReviewSubmissions",
                "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
            }
        },
    )
    if st_sub in (200, 201):
        review_state = sub_resp.get("data", {}).get("attributes", {}).get("betaReviewState", "SUBMITTED")
        print(f"Submitted build {build_id} for External TestFlight review (state={review_state}).", flush=True)
        return 0

    if is_already_in_review_error(st_sub, sub_resp):
        print(
            f"Notice: Beta App Review submission returned {st_sub} because a build is already "
            f"in review or cannot be re-submitted right now (non-fatal): {sub_resp}",
            flush=True,
        )
        return 0

    print(f"Error: Beta App Review submission failed ({st_sub}): {sub_resp}", file=sys.stderr, flush=True)
    return 1


if __name__ == "__main__":
    sys.exit(main())
