#ifndef SEARCHMYMAC_ENGINE_H
#define SEARCHMYMAC_ENGINE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Engine SMMEngine;

SMMEngine *smm_engine_open(const char *path);
SMMEngine *smm_engine_retain(SMMEngine *engine);
void smm_engine_release(SMMEngine *engine);
char *smm_engine_upsert(SMMEngine *engine, const char *json);
char *smm_engine_delete(SMMEngine *engine, const char *source_id);
char *smm_engine_commit(SMMEngine *engine);
char *smm_engine_search(SMMEngine *engine, const char *json);
void smm_string_free(char *value);

#ifdef __cplusplus
}
#endif

#endif
