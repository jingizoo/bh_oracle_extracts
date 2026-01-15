-- Simpler version that returns results as a queryable result set
-- This version creates a function that returns a table type

CREATE OR REPLACE TYPE resource_table_result AS OBJECT (
    schema_name VARCHAR2(128),
    table_name VARCHAR2(128),
    business_unit_column VARCHAR2(128),
    row_count NUMBER
);
/

CREATE OR REPLACE TYPE resource_table_tab AS TABLE OF resource_table_result;
/

CREATE OR REPLACE FUNCTION find_resource_tables_func(
    p_resource_id IN VARCHAR2,
    p_business_unit IN VARCHAR2,
    p_schema_name IN VARCHAR2 DEFAULT USER,
    p_include_all_schemas IN VARCHAR2 DEFAULT 'N'
) RETURN resource_table_tab PIPELINED AS
    v_sql VARCHAR2(4000);
    v_count NUMBER;
    v_table_name VARCHAR2(128);
    v_bu_column VARCHAR2(128);
    
    CURSOR c_tables IS
        SELECT DISTINCT
            CASE WHEN p_include_all_schemas = 'Y' THEN tc.owner ELSE USER END AS schema_name,
            tc.table_name,
            CASE 
                WHEN bu_pc.column_name IS NOT NULL THEN 'business_unit_pc'
                WHEN bu.column_name IS NOT NULL THEN 'business_unit'
            END AS bu_column
        FROM 
            (SELECT owner, table_name, column_name
             FROM all_tab_columns
             WHERE (p_include_all_schemas = 'Y' OR owner = UPPER(p_schema_name))
               AND column_name = 'RESOURCE_ID') res
        JOIN all_tab_columns bu
            ON bu.owner = res.owner
           AND bu.table_name = res.table_name
           AND bu.column_name = 'BUSINESS_UNIT'
        LEFT JOIN all_tab_columns bu_pc
            ON bu_pc.owner = res.owner
           AND bu_pc.table_name = res.table_name
           AND bu_pc.column_name = 'BUSINESS_UNIT_PC'
        WHERE bu.column_name IS NOT NULL OR bu_pc.column_name IS NOT NULL
        ORDER BY schema_name, table_name;
    
BEGIN
    FOR rec IN c_tables LOOP
        BEGIN
            v_table_name := rec.table_name;
            v_bu_column := rec.bu_column;
            
            v_sql := 'SELECT COUNT(*) FROM ' || rec.schema_name || '.' || rec.table_name ||
                     ' WHERE resource_id = :1 AND ' || v_bu_column || ' = :2';
            
            EXECUTE IMMEDIATE v_sql INTO v_count USING p_resource_id, p_business_unit;
            
            IF v_count > 0 THEN
                PIPE ROW(resource_table_result(
                    schema_name => rec.schema_name,
                    table_name => rec.table_name,
                    business_unit_column => v_bu_column,
                    row_count => v_count
                ));
            END IF;
            
        EXCEPTION
            WHEN OTHERS THEN
                NULL;
        END;
    END LOOP;
    
    RETURN;
END find_resource_tables_func;
/

-- Usage example:
-- SELECT * FROM TABLE(find_resource_tables_func('RESOURCE123', 'BU001', USER, 'N'));
-- 
-- Or with specific schema:
-- SELECT * FROM TABLE(find_resource_tables_func('RESOURCE123', 'BU001', 'SCHEMA_NAME', 'N'));
--
-- To search all schemas (requires appropriate privileges):
-- SELECT * FROM TABLE(find_resource_tables_func('RESOURCE123', 'BU001', NULL, 'Y'));


