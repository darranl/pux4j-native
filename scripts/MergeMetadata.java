///usr/bin/env jbang "$0" "$@" ; exit $?
//JAVA 25
//DEPS jakarta.json:jakarta.json-api:2.1.3
//DEPS org.eclipse.parsson:parsson:1.1.7

import jakarta.json.*;
import jakarta.json.stream.JsonGenerator;
import java.io.*;
import java.nio.file.*;
import java.nio.file.StandardOpenOption;
import java.util.Map;

/**
 * Convert GraalVM tracing agent output to the consolidated reachability-metadata.json format.
 *
 * The tracing agent writes separate JSON files (reflect-config.json, resource-config.json,
 * jni-config.json). This script combines them into the consolidated reachability-metadata.json
 * format supported by native-maven-plugin 0.11.x.
 *
 * Manual augmentations (shader wildcards, service loader entries) live in
 * augment/resource-config.json and are picked up separately by native-image — they do
 * NOT need to be included here.
 *
 * Usage: jbang MergeMetadata.java --generated <dir> --output <file>
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

        Path genDir = Path.of(generatedDir);

        JsonArray reflection = readArray(genDir.resolve("reflect-config.json"));
        JsonArray jni        = readArray(genDir.resolve("jni-config.json"));

        var resourceResult  = readResources(genDir.resolve("resource-config.json"));
        JsonArray resources = resourceResult[0];
        JsonArray bundles   = resourceResult[1];

        // Combine resources + bundles into one array (bundles use the "bundle" key)
        JsonArrayBuilder allResources = Json.createArrayBuilder();
        resources.forEach(allResources::add);
        bundles.forEach(allResources::add);
        JsonArray combinedResources = allResources.build();

        JsonObjectBuilder result = Json.createObjectBuilder();
        if (!reflection.isEmpty())        result.add("reflection", reflection);
        if (!combinedResources.isEmpty()) result.add("resources",  combinedResources);
        if (!jni.isEmpty())               result.add("jni",        jni);

        Path outPath = Path.of(outputFile);
        Files.createDirectories(outPath.getParent());
        var writerConfig = Map.of(JsonGenerator.PRETTY_PRINTING, true);
        try (JsonWriter writer = Json.createWriterFactory(writerConfig)
                                     .createWriter(Files.newBufferedWriter(outPath))) {
            writer.write(result.build());
        }
        // Jakarta JSON-P omits a trailing newline — add one for clean diffs
        try (var out = Files.newOutputStream(outPath, StandardOpenOption.APPEND)) {
            out.write('\n');
        }

        System.out.println("Written: " + outputFile);
        System.out.printf("  reflection entries : %d%n", reflection.size());
        System.out.printf("  resource entries   : %d%n", resources.size());
        System.out.printf("  bundle entries     : %d%n", bundles.size());
        System.out.printf("  jni entries        : %d%n", jni.size());
        System.out.println();
        System.out.println("Note: augment/resource-config.json is picked up separately by native-image.");
    }

    /** Read a JSON array file, returning an empty array if the file does not exist. */
    static JsonArray readArray(Path path) throws IOException {
        if (!Files.exists(path)) return JsonValue.EMPTY_JSON_ARRAY;
        try (JsonReader r = Json.createReader(Files.newBufferedReader(path))) {
            return r.readArray();
        }
    }

    /**
     * Read resource-config.json and return [resources, bundles] as separate arrays.
     *
     * Handles both the old format {"resources": {"includes": [{"pattern":"..."}]}}
     * and the newer format {"resources": [{...}]}.
     * Converts bundle entries from {"name":"..."} to {"bundle":"..."} for the combined format.
     */
    static JsonArray[] readResources(Path path) throws IOException {
        if (!Files.exists(path)) {
            return new JsonArray[]{JsonValue.EMPTY_JSON_ARRAY, JsonValue.EMPTY_JSON_ARRAY};
        }
        JsonObject cfg;
        try (JsonReader r = Json.createReader(Files.newBufferedReader(path))) {
            cfg = r.readObject();
        }

        // Normalise the resources array
        JsonArray resourceArray;
        JsonValue rawResources = cfg.get("resources");
        if (rawResources instanceof JsonArray arr) {
            resourceArray = arr;
        } else if (rawResources instanceof JsonObject obj && obj.containsKey("includes")) {
            // Old format: convert patterns to globs
            JsonArrayBuilder builder = Json.createArrayBuilder();
            for (JsonValue entry : obj.getJsonArray("includes")) {
                if (entry instanceof JsonObject e && e.containsKey("pattern")) {
                    builder.add(Json.createObjectBuilder().add("glob", e.getString("pattern")));
                } else {
                    builder.add(entry);
                }
            }
            resourceArray = builder.build();
        } else {
            resourceArray = JsonValue.EMPTY_JSON_ARRAY;
        }

        // Normalise bundles: {"name":"..."} → {"bundle":"..."}
        JsonArrayBuilder bundleBuilder = Json.createArrayBuilder();
        for (JsonValue b : (JsonArray) cfg.getOrDefault("bundles", JsonValue.EMPTY_JSON_ARRAY)) {
            if (b instanceof JsonObject bundleObj) {
                if (bundleObj.containsKey("name")) {
                    bundleBuilder.add(
                        Json.createObjectBuilder().add("bundle", bundleObj.getString("name")));
                } else {
                    bundleBuilder.add(bundleObj); // already uses "bundle" key
                }
            }
        }

        return new JsonArray[]{resourceArray, bundleBuilder.build()};
    }
}
