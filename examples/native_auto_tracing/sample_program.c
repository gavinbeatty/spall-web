#ifdef _WIN32
# include <windows.h>
#else
# include <pthread.h>
#endif
#include <stdlib.h>
#include <stdio.h>

#include "spall_native_auto.h"

void bar(void) {
}
void foo(void) {
	bar();
}
void wub(void) {
	printf("Foobar is terrible\n");
}

void do_work(void) {
	for (int i = 0; i < 1000; i++) {
		foo();
	}
}

#if defined(_WIN32) || defined(_WIN64)
DWORD WINAPI run_work(LPVOID ptr) {
	spall_auto_thread_init((uint32_t)GetCurrentThreadId(), SPALL_DEFAULT_BUFFER_SIZE);
	do_work();
	spall_auto_thread_quit();
	return 0;
}
#else
void *run_work(void *ptr) {
	spall_auto_thread_init((uint32_t)(uint64_t)pthread_self(), SPALL_DEFAULT_BUFFER_SIZE);
	do_work();
	spall_auto_thread_quit();
	return NULL;
}
#endif

int main(void) {
	spall_auto_init((char *)"profile.spall");
	spall_auto_thread_init(0, SPALL_DEFAULT_BUFFER_SIZE);

#if defined(_WIN32) || defined(_WIN64)
	DWORD dwthreads[2] = {0};
	HANDLE hthreads[2] = {0};
	hthreads[0] = CreateThread(NULL, 0, run_work, NULL, 0, &dwthreads[0]);
	if (hthreads[0] == NULL) abort();
	hthreads[1] = CreateThread(NULL, 0, run_work, NULL, 0, &dwthreads[1]);
	if (hthreads[1] == NULL) abort();
#else
	pthread_t thread_1, thread_2;
	pthread_create(&thread_1, NULL, run_work, NULL);
	pthread_create(&thread_2, NULL, run_work, NULL);
#endif

	for (int i = 0; i < 1000; i++) {
		foo();
	}

	wub();

#if defined(_WIN32) || defined(_WIN64)
	WaitForMultipleObjects(2, hthreads, TRUE, INFINITE);
	CloseHandle(hthreads[0]);
	CloseHandle(hthreads[1]);
#else
	pthread_join(thread_1, NULL);
	pthread_join(thread_2, NULL);
#endif

	spall_auto_thread_quit();
	spall_auto_quit();
}

#define SPALL_AUTO_IMPLEMENTATION
#include "spall_native_auto.h"
