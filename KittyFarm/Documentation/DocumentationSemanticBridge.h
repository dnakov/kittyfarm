#import <stdbool.h>

int doq_docs_available(char **err_out);
char *doq_docs_search_json(const char *query, const char *frameworks_json, const char *kinds_json, int limit, bool omit_content, char **err_out);
char *doq_docs_get_json(const char *identifier, char **err_out);
void doq_docs_free(char *ptr);
