#include <jni.h>
#include <stdlib.h>
#include "_cgo_export.h"

JNIEXPORT jstring JNICALL
Java_de_quickconnect_app_NativeLan_start(JNIEnv *env, jobject self, jstring ip,
                                         jstring host, jint port, jbyteArray key) {
    const char *local = (*env)->GetStringUTFChars(env, ip, NULL);
    if (local == NULL) return NULL;
    const char *target = (*env)->GetStringUTFChars(env, host, NULL);
    if (target == NULL) {
        (*env)->ReleaseStringUTFChars(env, ip, local);
        return NULL;
    }
    jbyte *bytes = (*env)->GetByteArrayElements(env, key, NULL);
    char *error = NULL;
    if (bytes != NULL) {
        error = qcStart((char *)local, (char *)target, port, bytes,
                        (*env)->GetArrayLength(env, key));
        (*env)->ReleaseByteArrayElements(env, key, bytes, JNI_ABORT);
    }
    (*env)->ReleaseStringUTFChars(env, host, target);
    (*env)->ReleaseStringUTFChars(env, ip, local);
    jstring result = error == NULL ? NULL : (*env)->NewStringUTF(env, error);
    free(error);
    return result;
}

JNIEXPORT void JNICALL
Java_de_quickconnect_app_NativeLan_stop(JNIEnv *env, jobject self) {
    qcStop();
}

JNIEXPORT jstring JNICALL
Java_de_quickconnect_app_NativeLan_events(JNIEnv *env, jobject self) {
    char *events = qcEvents();
    jstring result = events == NULL ? NULL : (*env)->NewStringUTF(env, events);
    free(events);
    return result;
}
