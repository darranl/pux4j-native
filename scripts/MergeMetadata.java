///usr/bin/env jbang "$0" "$@" ; exit $?
//JAVA 25
//DEPS jakarta.json:jakarta.json-api:2.1.3
//DEPS org.eclipse.parsson:parsson:1.1.7

import jakarta.json.*;
import java.io.*;
import java.nio.file.*;
import java.util.*;

/**
 * Additively merge a freshly-captured reachability-metadata.json (from the GraalVM tracing
 * agent's config-output-dir) into the project's real, committed reachability-metadata.json.
 *
 * GraalVM's native-image-agent (current unified schema, top-level keys "reflection",
 * "resources", "foreign", ...) already writes reachability-metadata.json directly in the
 * format this project wants — there is no legacy reflect-config.json/resource-config.json/
 * jni-config.json to convert (that was the old, GraalVM-CE-25.0.2-era agent output format;
 * see metadata-notes.md's "GraalVM version gotcha" for the history of the bug this replaced).
 *
 * This tool never removes an entry. Any single tracing run only exercises the code paths its
 * app/profile actually touches, so previously-captured coverage (e.g. hardware-only FFM
 * downcalls, or another app's reflection needs) would be silently destroyed by an overwrite —
 * this merges instead:
 *   - "reflection": entries are merged by "type"; methods/fields are unioned (deduped by their
 *     own structural identity), boolean flags (jniAccessible, etc.) are OR'd, and brand-new
 *     types are appended.
 *   - Every other array (resources, foreign.downcalls, and any future array) is deduped by
 *     full structural equality and unioned, preserving existing order and appending new
 *     entries at the end.
 *   - Every other object (foreign, and any future nested object) is merged key-by-key with the
 *     same rules, recursively.
 * Base entries are never reordered and never dropped — only appended to or extended — so this
 * is safe to run after every tracing session without manual review of the JSON itself (though
 * reviewing `git diff` before committing is still good practice, to sanity-check what got
 * captured).
 *
 * Usage: jbang MergeMetadata.java --generated <dir> --output <file>
 *   --generated <dir>   Directory containing the agent's freshly-written reachability-metadata.json
 *   --output <file>     The project's real reachability-metadata.json — read as the base and
 *                        overwritten in place with the merged result.
 */
public class MergeMetadata {

    public static void main(String[] args) throws IOException {
        String generatedDir = null;
        String outputFile = null;
        for (int i = 0; i < args.length; i++) {
            if ("--generated".equals(args[i]) && i + 1 < args.length) {
                generatedDir = args[++i];
            } else if ("--output".equals(args[i]) && i + 1 < args.length) {
                outputFile = args[++i];
            }
        }
        if (generatedDir == null || outputFile == null) {
            System.err.println("Usage: MergeMetadata.java --generated <dir> --output <file>");
            System.exit(1);
        }

        Path generatedFile = Path.of(generatedDir).resolve("reachability-metadata.json");
        Path outPath = Path.of(outputFile);

        if (!Files.exists(generatedFile)) {
            System.err.println("ERROR: " + generatedFile + " not found.");
            System.err.println("  The tracing agent only flushes its config on a clean JVM exit —");
            System.err.println("  a force-killed or forcibly-closed window produces no output.");
            System.exit(1);
        }

        JsonObject base = readObject(outPath);
        JsonObject captured = readObject(generatedFile);

        Set<String> allKeys = new LinkedHashSet<>();
        allKeys.addAll(base.keySet());
        allKeys.addAll(captured.keySet());

        Map<String, int[]> counts = new LinkedHashMap<>(); // key -> [before, after]
        JsonObjectBuilder result = Json.createObjectBuilder();
        for (String key : allKeys) {
            JsonValue bv = base.get(key);
            JsonValue ev = captured.get(key);
            if (bv == null) {
                result.add(key, ev);
                counts.put(key, new int[]{0, sizeOf(ev)});
            } else if (ev == null) {
                result.add(key, bv);
                counts.put(key, new int[]{sizeOf(bv), sizeOf(bv)});
            } else if ("reflection".equals(key)) {
                JsonArray merged = mergeReflection(bv.asJsonArray(), ev.asJsonArray());
                result.add(key, merged);
                counts.put(key, new int[]{bv.asJsonArray().size(), merged.size()});
            } else if (bv.getValueType() == JsonValue.ValueType.ARRAY && ev.getValueType() == JsonValue.ValueType.ARRAY) {
                JsonArray merged = unionArraysPreserveOrder(bv.asJsonArray(), ev.asJsonArray());
                result.add(key, merged);
                counts.put(key, new int[]{bv.asJsonArray().size(), merged.size()});
            } else if (bv.getValueType() == JsonValue.ValueType.OBJECT && ev.getValueType() == JsonValue.ValueType.OBJECT) {
                JsonObject merged = mergeGenericObject(bv.asJsonObject(), ev.asJsonObject());
                result.add(key, merged);
                counts.put(key, new int[]{sizeOf(bv), sizeOf(merged)});
            } else {
                result.add(key, bv);
                counts.put(key, new int[]{sizeOf(bv), sizeOf(bv)});
            }
        }

        Files.createDirectories(outPath.toAbsolutePath().getParent());
        // Jakarta JSON-P's own PRETTY_PRINTING (4-space indent, expands even empty arrays to
        // "[\n]") does not match this file's existing style (2-space indent, "[]" inline) and
        // would rewrite every line on every merge. writeCompact() reproduces the existing style
        // exactly, so a merge only ever touches genuinely new/changed lines.
        try (var out = Files.newBufferedWriter(outPath)) {
            writeCompact(result.build(), 0, out);
            out.write('\n');
        }

        System.out.println("Merged: " + outputFile);
        for (var e : counts.entrySet()) {
            int before = e.getValue()[0], after = e.getValue()[1];
            String delta = after > before ? " (+" + (after - before) + ")" : "";
            System.out.printf("  %-12s: %d -> %d%s%n", e.getKey(), before, after, delta);
        }
        System.out.println();
        System.out.println("Additive merge only — no existing entry was removed or reordered.");
        System.out.println("Note: augment/resource-config.json is picked up separately by native-image.");
    }

    /**
     * Write JSON matching this file's existing style: 2-space indent, empty objects/arrays
     * kept inline ("{}"/"[]"), one entry per line otherwise. Object key order is preserved
     * exactly as built (LinkedHashMap-backed throughout this tool).
     */
    static void writeCompact(JsonValue v, int indent, Writer out) throws IOException {
        switch (v.getValueType()) {
            case OBJECT -> {
                JsonObject o = v.asJsonObject();
                if (o.isEmpty()) { out.write("{}"); return; }
                out.write("{\n");
                var it = o.entrySet().iterator();
                while (it.hasNext()) {
                    var e = it.next();
                    pad(out, indent + 1);
                    out.write(Json.createValue(e.getKey()).toString());
                    out.write(": ");
                    writeCompact(e.getValue(), indent + 1, out);
                    if (it.hasNext()) out.write(',');
                    out.write('\n');
                }
                pad(out, indent);
                out.write('}');
            }
            case ARRAY -> {
                JsonArray a = v.asJsonArray();
                if (a.isEmpty()) { out.write("[]"); return; }
                out.write("[\n");
                for (int i = 0; i < a.size(); i++) {
                    pad(out, indent + 1);
                    writeCompact(a.get(i), indent + 1, out);
                    if (i < a.size() - 1) out.write(',');
                    out.write('\n');
                }
                pad(out, indent);
                out.write(']');
            }
            default -> out.write(v.toString());
        }
    }

    static void pad(Writer out, int indent) throws IOException {
        out.write("  ".repeat(indent));
    }

    static int sizeOf(JsonValue v) {
        return switch (v.getValueType()) {
            case ARRAY -> v.asJsonArray().size();
            case OBJECT -> v.asJsonObject().size();
            default -> 1;
        };
    }

    static JsonObject readObject(Path path) throws IOException {
        if (!Files.exists(path)) return JsonValue.EMPTY_JSON_OBJECT;
        try (JsonReader r = Json.createReader(Files.newBufferedReader(path))) {
            return r.readObject();
        }
    }

    /** Recursively sort object keys (arrays keep their element order) for structural-equality dedup keys. */
    static JsonValue canonicalOrder(JsonValue v) {
        return switch (v.getValueType()) {
            case OBJECT -> {
                JsonObject o = v.asJsonObject();
                var b = Json.createObjectBuilder();
                o.keySet().stream().sorted().forEach(k -> b.add(k, canonicalOrder(o.get(k))));
                yield b.build();
            }
            case ARRAY -> {
                var b = Json.createArrayBuilder();
                for (JsonValue e : v.asJsonArray()) b.add(canonicalOrder(e));
                yield b.build();
            }
            default -> v;
        };
    }

    static String canon(JsonValue v) {
        return canonicalOrder(v).toString();
    }

    /** Union two arrays of arbitrary JSON values, deduped by structural equality, base order preserved. */
    static JsonArray unionArraysPreserveOrder(JsonArray base, JsonArray extra) {
        var seen = new LinkedHashMap<String, JsonValue>();
        for (JsonValue v : base) seen.putIfAbsent(canon(v), v);
        for (JsonValue v : extra) seen.putIfAbsent(canon(v), v);
        var b = Json.createArrayBuilder();
        seen.values().forEach(b::add);
        return b.build();
    }

    /** Merge two reflection arrays, keyed by "type": union methods/fields, OR boolean flags, append new types. */
    static JsonArray mergeReflection(JsonArray base, JsonArray extra) {
        var byType = new LinkedHashMap<String, JsonObject>();
        for (JsonValue v : base) {
            JsonObject o = v.asJsonObject();
            byType.put(o.getString("type"), o);
        }
        for (JsonValue v : extra) {
            JsonObject o = v.asJsonObject();
            String type = o.getString("type");
            byType.merge(type, o, MergeMetadata::mergeReflectionEntry);
        }
        var b = Json.createArrayBuilder();
        byType.values().forEach(b::add);
        return b.build();
    }

    static JsonObject mergeReflectionEntry(JsonObject base, JsonObject extra) {
        var keys = new LinkedHashSet<String>();
        keys.addAll(base.keySet());
        keys.addAll(extra.keySet());
        var result = Json.createObjectBuilder();
        for (String key : keys) {
            JsonValue bv = base.get(key);
            JsonValue ev = extra.get(key);
            if (bv == null) {
                result.add(key, ev);
            } else if (ev == null) {
                result.add(key, bv);
            } else if (bv.getValueType() == JsonValue.ValueType.ARRAY && ev.getValueType() == JsonValue.ValueType.ARRAY) {
                result.add(key, unionArraysPreserveOrder(bv.asJsonArray(), ev.asJsonArray()));
            } else if (isBoolean(bv) && isBoolean(ev)) {
                result.add(key, bv == JsonValue.TRUE || ev == JsonValue.TRUE);
            } else {
                result.add(key, bv); // e.g. "type" itself — identical on both sides
            }
        }
        return result.build();
    }

    static boolean isBoolean(JsonValue v) {
        return v.getValueType() == JsonValue.ValueType.TRUE || v.getValueType() == JsonValue.ValueType.FALSE;
    }

    /** Generic recursive object merge for anything that isn't "reflection" (e.g. "foreign"). */
    static JsonObject mergeGenericObject(JsonObject base, JsonObject extra) {
        var keys = new LinkedHashSet<String>();
        keys.addAll(base.keySet());
        keys.addAll(extra.keySet());
        var result = Json.createObjectBuilder();
        for (String key : keys) {
            JsonValue bv = base.get(key);
            JsonValue ev = extra.get(key);
            if (bv == null) {
                result.add(key, ev);
            } else if (ev == null) {
                result.add(key, bv);
            } else if (bv.getValueType() == JsonValue.ValueType.ARRAY && ev.getValueType() == JsonValue.ValueType.ARRAY) {
                result.add(key, unionArraysPreserveOrder(bv.asJsonArray(), ev.asJsonArray()));
            } else if (bv.getValueType() == JsonValue.ValueType.OBJECT && ev.getValueType() == JsonValue.ValueType.OBJECT) {
                result.add(key, mergeGenericObject(bv.asJsonObject(), ev.asJsonObject()));
            } else {
                result.add(key, bv);
            }
        }
        return result.build();
    }
}
