#!/usr/bin/env python3
"""Register / unregister a custom video in macOS Sequoia's Aerial catalog (entries.json + Aerial.sqlite).

  catalog.py entries add    --dir DIR --id UUID --name NAME [--category Custom]
  catalog.py entries remove --dir DIR --id UUID
  catalog.py sql add        --dir DIR --id UUID --name NAME [--category Custom] > out.sql
  catalog.py sql remove     --dir DIR --id UUID                                  > out.sql

DIR is /Library/Application Support/com.apple.idleassetsd. `sql` only prints SQL; install.sh runs it
(with sudo, after a backup). Nothing here touches the video file itself.
"""
import argparse, json, plistlib, sys, uuid
from urllib.parse import quote

def ids(a):
    cat = str(uuid.uuid5(uuid.NAMESPACE_DNS, "aerial-custom-video/category/" + a.category)).upper()
    sub = str(uuid.uuid5(uuid.NAMESPACE_DNS, "aerial-custom-video/subcategory/" + a.id)).upper()
    return cat, sub

def fileurl(a, path):
    return "file://" + quote(a.dir.rstrip("/") + "/" + path, safe="/")

def video_url(a): return fileurl(a, "Customer/4KSDR240FPS/%s.mov" % a.id)
def prev_url(a):  return fileurl(a, "snapshots/asset-preview-%s.jpg" % a.id)

# ---- entries.json -------------------------------------------------------------------------------------------
def entries(a):
    path = a.dir.rstrip("/") + "/Customer/entries.json"
    d = json.load(open(path))
    cat, sub = ids(a)
    # drop any previous registration of this asset
    d["assets"] = [x for x in d["assets"] if x["id"] != a.id]
    for c in d["categories"]:
        c["subcategories"] = [s for s in c.get("subcategories", []) if s["id"] != sub]
    if a.cmd2 == "add":
        asset = {"id": a.id, "shotID": "CUSTOM_" + a.id.replace("-", "_"), "accessibilityLabel": a.name, "localizedNameKey": a.name,
                 "url-4K-SDR-240FPS": video_url(a), "previewImage": prev_url(a),
                 "pointsOfInterest": {"0": "CUSTOM_%s_0" % a.id.replace("-", "_")},
                 "categories": [cat], "subcategories": [sub], "includeInShuffle": True, "showInTopLevel": True, "preferredOrder": 0}
        d["assets"].append(asset)
        subd = {"id": sub, "localizedNameKey": a.name, "localizedDescriptionKey": a.name, "previewImage": prev_url(a),
                "representativeAssetID": a.id, "preferredOrder": 0}
        c = next((c for c in d["categories"] if c["id"] == cat), None)
        if c is None:
            c = {"id": cat, "localizedNameKey": a.category, "localizedDescriptionKey": a.category, "previewImage": prev_url(a),
                 "representativeAssetID": a.id, "preferredOrder": max([x.get("preferredOrder", 0) for x in d["categories"]] + [0]) + 1,
                 "subcategories": []}
            d["categories"].append(c)
        c["subcategories"].append(subd)
    else:  # remove: drop our (uuid5-derived) categories that became empty
        ours = {str(uuid.uuid5(uuid.NAMESPACE_DNS, "aerial-custom-video/category/" + n)).upper() for n in [a.category]}
        d["categories"] = [c for c in d["categories"] if c.get("subcategories") or c["id"] not in ours]
    s = json.dumps(d, indent=2, separators=(",", " : "), ensure_ascii=False)
    json.loads(s)
    open(path, "w").write(s)

# ---- Aerial.sqlite ------------------------------------------------------------------------------------------
def keyed(objects):
    return plistlib.dumps({"$archiver": "NSKeyedArchiver", "$version": 100000, "$top": {"root": plistlib.UID(1)}, "$objects": objects}, fmt=plistlib.FMT_BINARY)

def remote_urls(a):   # NSMutableDictionary {"4KSDR240FPS": NSURL}
    return keyed(["$null", {"$class": plistlib.UID(6), "NS.keys": [plistlib.UID(2)], "NS.objects": [plistlib.UID(3)]}, "4KSDR240FPS",
                  {"$class": plistlib.UID(5), "NS.base": plistlib.UID(0), "NS.relative": plistlib.UID(4)}, video_url(a),
                  {"$classes": ["NSURL", "NSObject"], "$classname": "NSURL"},
                  {"$classes": ["NSMutableDictionary", "NSDictionary", "NSObject"], "$classname": "NSMutableDictionary"}])

def points(a):        # NSDictionary {"0": shotID}
    return keyed(["$null", {"$class": plistlib.UID(4), "NS.keys": [plistlib.UID(2)], "NS.objects": [plistlib.UID(3)]}, "0",
                  "CUSTOM_%s_0" % a.id.replace("-", "_"), {"$classes": ["NSDictionary", "NSObject"], "$classname": "NSDictionary"}])

q = lambda s: "'" + s.replace("'", "''") + "'"

def sql_remove(a, cat):
    A = "(SELECT Z_PK FROM ZASSET WHERE ZIDENTIFIER=%s)" % q(a.id)
    print("DELETE FROM Z_1CATEGORIES WHERE Z_1ASSETS1=%s;" % A)
    print("DELETE FROM Z_1SUBCATEGORIES WHERE Z_1ASSETS=%s;" % A)
    print("DELETE FROM Z_1PINNEDFORUSERS WHERE Z_1PINNEDASSETS=%s;" % A)
    print("DELETE FROM ZSUBCATEGORY WHERE ZREPRESENTATIVEASSET=%s;" % A)
    print("DELETE FROM ZASSET WHERE ZIDENTIFIER=%s;" % q(a.id))
    print("DELETE FROM Z_2ACTIVEFORUSERS WHERE Z_2ACTIVECATEGORIES IN (SELECT Z_PK FROM ZCATEGORY WHERE ZIDENTIFIER=%s AND Z_PK NOT IN (SELECT Z_2CATEGORIES FROM Z_1CATEGORIES));" % q(cat))
    print("DELETE FROM ZCATEGORY WHERE ZIDENTIFIER=%s AND Z_PK NOT IN (SELECT Z_2CATEGORIES FROM Z_1CATEGORIES);" % q(cat))

def sql(a):
    cat, sub = ids(a)
    print("BEGIN;")
    sql_remove(a, cat)
    if a.cmd2 == "add":
        print("INSERT INTO ZCATEGORY (Z_PK,Z_ENT,Z_OPT,ZISACTIVE,ZPREFERREDORDER,ZIDENTIFIER,ZLOCALIZEDDESCRIPTIONKEY,ZLOCALIZEDNAMEKEY,ZPREVIEWIMAGEURL) "
              "SELECT (SELECT IFNULL(MAX(Z_PK),0)+1 FROM ZCATEGORY),2,1,1,(SELECT IFNULL(MAX(ZPREFERREDORDER),0)+1 FROM ZCATEGORY),%s,%s,%s,%s "
              "WHERE NOT EXISTS (SELECT 1 FROM ZCATEGORY WHERE ZIDENTIFIER=%s);" % (q(cat), q(a.category), q(a.category), q(prev_url(a)), q(cat)))
        print("INSERT INTO ZASSET (Z_PK,Z_ENT,Z_OPT,ZINCLUDEINSHUFFLE,ZPLAYORDER,ZPREFERREDORDER,ZSHOWINTOPLEVEL,ZACCESSIBILITYLABEL,ZIDENTIFIER,ZLOCALIZEDNAMEKEY,ZSHOTID,ZPREVIEWIMAGEURL,ZPOINTSOFINTEREST,ZREMOTEURLS) "
              "VALUES ((SELECT IFNULL(MAX(Z_PK),0)+1 FROM ZASSET),1,1,1,-1,0,1,%s,%s,%s,%s,%s,X'%s',X'%s');"
              % (q(a.name), q(a.id), q(a.name), q("CUSTOM_" + a.id.replace("-", "_")), q(prev_url(a)), points(a).hex(), remote_urls(a).hex()))
        A = "(SELECT Z_PK FROM ZASSET WHERE ZIDENTIFIER=%s)" % q(a.id)
        C = "(SELECT Z_PK FROM ZCATEGORY WHERE ZIDENTIFIER=%s)" % q(cat)
        print("INSERT INTO ZSUBCATEGORY (Z_PK,Z_ENT,Z_OPT,ZISACTIVE,ZPREFERREDORDER,ZCATEGORY,ZREPRESENTATIVEASSET,ZIDENTIFIER,ZLOCALIZEDDESCRIPTIONKEY,ZLOCALIZEDNAMEKEY) "
              "VALUES ((SELECT IFNULL(MAX(Z_PK),0)+1 FROM ZSUBCATEGORY),3,1,0,0,%s,%s,%s,%s,%s);" % (C, A, q(sub), q(a.name), q(a.name)))
        S = "(SELECT Z_PK FROM ZSUBCATEGORY WHERE ZIDENTIFIER=%s)" % q(sub)
        print("INSERT INTO Z_1CATEGORIES (Z_1ASSETS1,Z_2CATEGORIES) VALUES (%s,%s);" % (A, C))
        print("INSERT INTO Z_1SUBCATEGORIES (Z_1ASSETS,Z_3SUBCATEGORIES) VALUES (%s,%s);" % (A, S))
    for ent, tbl in ((1, "ZASSET"), (2, "ZCATEGORY"), (3, "ZSUBCATEGORY")):   # Core Data's "next primary key" bookkeeping
        print("UPDATE Z_PRIMARYKEY SET Z_MAX=(SELECT IFNULL(MAX(Z_PK),0) FROM %s) WHERE Z_ENT=%d;" % (tbl, ent))
    print("COMMIT;")

p = argparse.ArgumentParser()
p.add_argument("kind", choices=["entries", "sql"]); p.add_argument("cmd2", choices=["add", "remove"])
p.add_argument("--dir", required=True); p.add_argument("--id", required=True)
p.add_argument("--name", default=""); p.add_argument("--category", default="Custom")
a = p.parse_args()
a.id = a.id.upper()
if a.cmd2 == "add" and not a.name: p.error("--name is required for add")
(entries if a.kind == "entries" else sql)(a)
