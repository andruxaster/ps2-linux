/* Проверка тулчейна: printf, float (single/double через soft-float), pthread,
 * атомики (LL/SC эмулируются ядром на R5900), чтение /proc/cpuinfo. */
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

static atomic_int counter;

static void *worker(void *arg)
{
	for (int i = 0; i < 100000; i++)
		atomic_fetch_add(&counter, 1);
	return arg;
}

int main(void)
{
	pthread_t t[4];
	for (int i = 0; i < 4; i++)
		pthread_create(&t[i], NULL, worker, NULL);
	for (int i = 0; i < 4; i++)
		pthread_join(t[i], NULL);

	volatile float f = 1.5f;
	volatile double d = 2.25;
	printf("Hello, PlayStation 2!\n");
	printf("atomic counter = %d (ожидается 400000)\n", atomic_load(&counter));
	printf("float %.3f * double %.3f = %.4f\n", f, d, f * d);

	FILE *c = fopen("/proc/cpuinfo", "r");
	char line[256];
	while (c && fgets(line, sizeof(line), c))
		if (!strncmp(line, "cpu model", 9) || !strncmp(line, "system type", 11))
			fputs(line, stdout);
	if (c)
		fclose(c);
	return atomic_load(&counter) == 400000 ? 0 : 1;
}
