#include <jni.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <signal.h>
#include <android/log.h>

#define TAG "qtermpty"

static jlong pack(int pid, int fd) {
    return ((jlong)pid << 32) | (fd & 0xffffffffL);
}
static int pid_of(jlong h) { return (int)(h >> 32); }
static int fd_of(jlong h) { return (int)(h & 0xffffffffL); }

static char **jstring_array_to_c(JNIEnv *env, jobjectArray arr) {
    if (arr == NULL) return NULL;
    int len = (*env)->GetArrayLength(env, arr);
    char **out = calloc((size_t)len + 1, sizeof(char *));
    if (!out) return NULL;
    for (int i = 0; i < len; i++) {
        jstring js = (jstring)(*env)->GetObjectArrayElement(env, arr, i);
        const char *s = (*env)->GetStringUTFChars(env, js, NULL);
        out[i] = strdup(s);
        (*env)->ReleaseStringUTFChars(env, js, s);
        (*env)->DeleteLocalRef(env, js);
    }
    return out;
}

static void free_string_array(char **arr) {
    if (!arr) return;
    for (int i = 0; arr[i]; i++) free(arr[i]);
    free(arr);
}

JNIEXPORT jlong JNICALL
Java_com_example_qinglong_1flutter_ProotBridge_ptySpawn(
    JNIEnv *env, jobject thiz, jobjectArray cmd, jobjectArray envArr, jstring cwd) {

    char **argv = jstring_array_to_c(env, cmd);
    char **envp = jstring_array_to_c(env, envArr);
    const char *cwd_c = cwd ? (*env)->GetStringUTFChars(env, cwd, NULL) : NULL;
    if (!argv || !argv[0]) {
        free_string_array(argv);
        free_string_array(envp);
        if (cwd_c) (*env)->ReleaseStringUTFChars(env, cwd, cwd_c);
        return -1;
    }

    int master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0) {
        __android_log_print(ANDROID_LOG_ERROR, TAG, "posix_openpt failed: %s", strerror(errno));
        free_string_array(argv);
        free_string_array(envp);
        if (cwd_c) (*env)->ReleaseStringUTFChars(env, cwd, cwd_c);
        return -1;
    }
    if (grantpt(master) != 0 || unlockpt(master) != 0) {
        __android_log_print(ANDROID_LOG_ERROR, TAG, "grant/unlockpt failed: %s", strerror(errno));
        close(master);
        free_string_array(argv);
        free_string_array(envp);
        if (cwd_c) (*env)->ReleaseStringUTFChars(env, cwd, cwd_c);
        return -1;
    }
    char *slave_name = ptsname(master);
    if (!slave_name) {
        __android_log_print(ANDROID_LOG_ERROR, TAG, "ptsname failed: %s", strerror(errno));
        close(master);
        free_string_array(argv);
        free_string_array(envp);
        if (cwd_c) (*env)->ReleaseStringUTFChars(env, cwd, cwd_c);
        return -1;
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(master);
        free_string_array(argv);
        free_string_array(envp);
        if (cwd_c) (*env)->ReleaseStringUTFChars(env, cwd, cwd_c);
        return -1;
    }

    if (pid == 0) {
        // Child: attach to a new session and make the slave our controlling tty.
        setsid();
        int tty = open(slave_name, O_RDWR);
        if (tty >= 0) {
            ioctl(tty, TIOCSCTTY, 0);
            dup2(tty, 0);
            dup2(tty, 1);
            dup2(tty, 2);
            if (tty > 2) close(tty);
        }
        close(master);
        if (cwd_c) chdir(cwd_c);
        execve(argv[0], argv, envp);
        _exit(127);
    }

    // Parent: keep the master fd open, it is returned to Java.
    free_string_array(argv);
    free_string_array(envp);
    if (cwd_c) (*env)->ReleaseStringUTFChars(env, cwd, cwd_c);
    return pack((int)pid, master);
}

JNIEXPORT jint JNICALL
Java_com_example_qinglong_1flutter_ProotBridge_ptyResize(
    JNIEnv *env, jobject thiz, jlong handle, jint cols, jint rows) {
    // 不告诉 pty 窗口大小的话，内核里的 winsize 是 0x0：
    // bash 认为终端零宽，ls 不分列、less/top 画不出界面、长命令换行位置全错。
    // 所以每次 TerminalView 尺寸变化都要把新的行列数写进来。
    if (cols <= 0 || rows <= 0) return -1;
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_col = (unsigned short)cols;
    ws.ws_row = (unsigned short)rows;
    int fd = fd_of(handle);
    if (ioctl(fd, TIOCSWINSZ, &ws) != 0) {
        __android_log_print(ANDROID_LOG_WARN, TAG, "TIOCSWINSZ failed: %s", strerror(errno));
        return -1;
    }
    // 前台进程组要收到 SIGWINCH 才会重排界面（vim/top/htop 靠这个）。
    pid_t pgrp = tcgetpgrp(fd);
    if (pgrp > 0) killpg(pgrp, SIGWINCH);
    return 0;
}

JNIEXPORT jint JNICALL
Java_com_example_qinglong_1flutter_ProotBridge_ptyRead(
    JNIEnv *env, jobject thiz, jlong handle, jbyteArray buffer, jint offset, jint length) {
    int fd = fd_of(handle);
    char *tmp = (char *)malloc((size_t)length);
    if (!tmp) return -1;
    ssize_t n = read(fd, tmp, (size_t)length);
    if (n > 0) {
        (*env)->SetByteArrayRegion(env, buffer, offset, (jsize)n, (jbyte *)tmp);
    }
    free(tmp);
    return (jint)n;
}

JNIEXPORT jint JNICALL
Java_com_example_qinglong_1flutter_ProotBridge_ptyWrite(
    JNIEnv *env, jobject thiz, jlong handle, jbyteArray data, jint offset, jint length) {
    int fd = fd_of(handle);
    jbyte *bytes = (*env)->GetByteArrayElements(env, data, NULL);
    ssize_t n = write(fd, bytes + offset, (size_t)length);
    (*env)->ReleaseByteArrayElements(env, data, bytes, JNI_ABORT);
    return (jint)n;
}

JNIEXPORT void JNICALL
Java_com_example_qinglong_1flutter_ProotBridge_ptyClose(
    JNIEnv *env, jobject thiz, jlong handle) {
    close(fd_of(handle));
}

JNIEXPORT void JNICALL
Java_com_example_qinglong_1flutter_ProotBridge_ptyKill(
    JNIEnv *env, jobject thiz, jlong handle) {
    int pid = pid_of(handle);
    // 子进程调用了 setsid()，整个会话的进程组 id = pid。
    kill(-pid, SIGKILL);
    kill(pid, SIGKILL);
}

JNIEXPORT jint JNICALL
Java_com_example_qinglong_1flutter_ProotBridge_ptyWait(
    JNIEnv *env, jobject thiz, jlong handle) {
    int pid = pid_of(handle);
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) return -1;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -1;
}
