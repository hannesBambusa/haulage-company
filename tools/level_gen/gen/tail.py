# ------------------------------------------------------------------- write
out = ['[gd_scene load_steps=%d format=3]\n' % (len(ext) + len(subs) + 1)]
for path, (rid, typ) in ext.items():
    out.append('[ext_resource type="%s" path="%s" id="%s"]' % (typ, path, rid))
out.append("")
out += subs
out += nodes
open(OUT, "w").write("\n".join(out))
print("wrote", OUT, len(nodes), "nodes")
