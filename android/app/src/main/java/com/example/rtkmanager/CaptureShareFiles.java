package com.example.rtkmanager;

import java.io.BufferedOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

/** Prepares one shareable attachment without modifying the recorded files. */
public final class CaptureShareFiles {
    private CaptureShareFiles() {}

    /** Run on the capture worker after recording has stopped. */
    public static File prepare(File root, File cache, List<String> paths) throws IOException {
        if (paths.isEmpty()) throw new IllegalArgumentException("没有可分享的文件");
        File canonicalRoot = root.getCanonicalFile();
        String prefix = canonicalRoot.getPath() + File.separator;
        LinkedHashSet<File> unique = new LinkedHashSet<>();
        for (String path : paths) {
            File file = new File(path).getCanonicalFile();
            if (!file.isFile() || !file.getPath().startsWith(prefix)) {
                throw new IllegalArgumentException("文件不在采集目录中或已不存在");
            }
            unique.add(file);
        }
        List<File> files = new ArrayList<>(unique);
        if (files.size() == 1) return files.get(0);

        File directory = new File(cache, "capture-share");
        if (!directory.isDirectory() && !directory.mkdirs()) {
            throw new IOException("无法创建分享缓存目录");
        }
        // Leave recent attachments available while a receiving app reads them.
        // Only our temporary ZIPs are eligible for cleanup, never source data.
        File[] previous = directory.listFiles();
        long cutoff = System.currentTimeMillis() - 24L * 60 * 60 * 1000;
        if (previous != null) {
            for (File file : previous) {
                if (file.isFile() && file.getName().startsWith("Capture_")
                        && file.getName().endsWith(".zip") && file.lastModified() < cutoff) {
                    file.delete();
                }
            }
        }
        File archive = File.createTempFile("Capture_", ".zip", directory);
        boolean complete = false;
        try {
            try (ZipOutputStream output = new ZipOutputStream(
                    new BufferedOutputStream(new FileOutputStream(archive)))) {
                byte[] buffer = new byte[64 * 1024];
                for (File file : files) {
                    // Retain session-relative folders, so identically named
                    // files from different sessions do not overwrite each other.
                    String entry = file.getPath().substring(prefix.length())
                            .replace(File.separatorChar, '/');
                    output.putNextEntry(new ZipEntry(entry));
                    try (FileInputStream input = new FileInputStream(file)) {
                        int count;
                        while ((count = input.read(buffer)) != -1) {
                            output.write(buffer, 0, count);
                        }
                    }
                    output.closeEntry();
                }
            }
            complete = true;
            return archive;
        } finally {
            if (!complete) archive.delete();
        }
    }
}
