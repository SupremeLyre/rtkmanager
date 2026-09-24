import com.example.rtkmanager.CaptureShareFiles;
import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.Collections;
import java.util.zip.ZipFile;

public class CaptureShareFilesCheck {
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    public static void main(String[] args) throws Exception {
        Path directory = Files.createTempDirectory(Path.of("build"), "capture-share-check-");
        File root = Files.createDirectories(directory.resolve("PhoneCapture")).toFile();
        File cache = Files.createDirectories(directory.resolve("cache")).toFile();
        Path first = Files.createDirectories(root.toPath().resolve("Capture_A")).resolve("imu.bin");
        Path second = Files.createDirectories(root.toPath().resolve("Capture_B")).resolve("imu.bin");
        byte[] payload = new byte[200_003];
        for (int i = 0; i < payload.length; i++) payload[i] = (byte) (i % 251);
        Files.write(first, payload);
        Files.write(second, new byte[] {3, 2, 1});

        File single = CaptureShareFiles.prepare(root, cache, Collections.singletonList(first.toString()));
        check(single.equals(first.toFile().getCanonicalFile()), "single file shared directly");
        File archive = CaptureShareFiles.prepare(root, cache,
                Arrays.asList(first.toString(), second.toString(), first.toString()));
        try (ZipFile zip = new ZipFile(archive)) {
            check(zip.size() == 2, "deduplicate input without dropping distinct session files");
            check(Arrays.equals(zip.getInputStream(zip.getEntry("Capture_A/imu.bin")).readAllBytes(), payload),
                    "preserve binary bytes across streaming buffer boundaries");
            check(Arrays.equals(zip.getInputStream(zip.getEntry("Capture_B/imu.bin")).readAllBytes(),
                    new byte[] {3, 2, 1}), "retain same-named file from another session");
        }
        check(Arrays.equals(Files.readAllBytes(first), payload), "source remains unchanged");

        Path outside = Files.createDirectories(directory.resolve("PhoneCapture-other")).resolve("secret.bin");
        Files.write(outside, new byte[] {9});
        for (String invalid : Arrays.asList(outside.toString(), root + "/../PhoneCapture-other/secret.bin",
                root + "/missing.bin", root.toString())) {
            boolean rejected = false;
            try { CaptureShareFiles.prepare(root, cache, Arrays.asList(first.toString(), invalid)); }
            catch (IllegalArgumentException expected) { rejected = true; }
            check(rejected, "reject missing/outside/directory attachment: " + invalid);
        }
        boolean emptyRejected = false;
        try { CaptureShareFiles.prepare(root, cache, Collections.emptyList()); }
        catch (IllegalArgumentException expected) { emptyRejected = true; }
        check(emptyRejected, "reject empty selection");

        check(archive.setLastModified(System.currentTimeMillis() - 48L * 60 * 60 * 1000), "age cached ZIP");
        File next = CaptureShareFiles.prepare(root, cache, Arrays.asList(first.toString(), second.toString()));
        check(!archive.exists() && next.isFile() && first.toFile().isFile(), "prune only expired cached ZIPs");
        System.out.println("PASS: single attachment, streamed ZIP contents, paths, deduplication, cache cleanup");
    }
}
