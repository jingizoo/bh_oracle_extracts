CREATE OR REPLACE PROCEDURE find_resource_tables(
    p_resource_id IN VARCHAR2,
    p_business_unit IN VARCHAR2,
    p_schema_name IN VARCHAR2 DEFAULT USER,
    p_include_all_schemas IN VARCHAR2 DEFAULT 'N'
) AS
    v_sql VARCHAR2(4000);
    v_count NUMBER;
    v_table_name VARCHAR2(128);
    v_bu_column VARCHAR2(128);
    
    TYPE result_rec IS RECORD (
        schema_name VARCHAR2(128),
        table_name VARCHAR2(128),
        business_unit_column VARCHAR2(128),
        row_count NUMBER
    );
    
    TYPE result_tab IS TABLE OF result_rec;
    v_results result_tab := result_tab();
    
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
             WHERE (p_include_all_schemas = 'Y' OR owner = p_schema_name)
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
    DBMS_OUTPUT.PUT_LINE('Searching for tables with RESOURCE_ID and BUSINESS_UNIT/BUSINESS_UNIT_PC...');
    DBMS_OUTPUT.PUT_LINE('Resource ID: ' || p_resource_id);
    DBMS_OUTPUT.PUT_LINE('Business Unit: ' || p_business_unit);
    DBMS_OUTPUT.PUT_LINE('Schema: ' || p_schema_name);
    DBMS_OUTPUT.PUT_LINE('Include All Schemas: ' || p_include_all_schemas);
    DBMS_OUTPUT.PUT_LINE('-' || RPAD('-', 80, '-'));
    
    FOR rec IN c_tables LOOP
        BEGIN
            v_table_name := rec.table_name;
            v_bu_column := rec.bu_column;
            
            v_sql := 'SELECT COUNT(*) FROM ' || rec.schema_name || '.' || rec.table_name ||
                     ' WHERE resource_id = :1 AND ' || v_bu_column || ' = :2';
            
            EXECUTE IMMEDIATE v_sql INTO v_count USING p_resource_id, p_business_unit;
            
            IF v_count > 0 THEN
                v_results.EXTEND;
                v_results(v_results.COUNT) := result_rec(
                    schema_name => rec.schema_name,
                    table_name => rec.table_name,
                    business_unit_column => v_bu_column,
                    row_count => v_count
                );
                
                DBMS_OUTPUT.PUT_LINE(
                    RPAD(rec.schema_name || '.' || rec.table_name, 50) ||
                    RPAD(v_bu_column, 20) ||
                    LPAD(TO_CHAR(v_count), 10) || ' row(s)'
                );
            END IF;
            
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('ERROR checking ' || rec.schema_name || '.' || rec.table_name || 
                                   ': ' || SQLERRM);
        END;
    END LOOP;
    
    DBMS_OUTPUT.PUT_LINE('-' || RPAD('-', 80, '-'));
    DBMS_OUTPUT.PUT_LINE('Total tables found: ' || v_results.COUNT);
    
END find_resource_tables;
/

-- Alternative version that returns results via REF CURSOR (better for calling from applications)
CREATE OR REPLACE PROCEDURE find_resource_tables_cursor(
    p_resource_id IN VARCHAR2,
    p_business_unit IN VARCHAR2,
    p_schema_name IN VARCHAR2 DEFAULT USER,
    p_include_all_schemas IN VARCHAR2 DEFAULT 'N',
    p_result_cursor OUT SYS_REFCURSOR
) AS
    v_sql VARCHAR2(4000);
    v_count NUMBER;
    v_table_name VARCHAR2(128);
    v_bu_column VARCHAR2(128);
    
    v_results_sql CLOB;
    
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
             WHERE (p_include_all_schemas = 'Y' OR owner = p_schema_name)
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
    v_results_sql := 'SELECT schema_name, table_name, business_unit_column, row_count FROM (';
    
    FOR rec IN c_tables LOOP
        BEGIN
            v_table_name := rec.table_name;
            v_bu_column := rec.bu_column;
            
            v_sql := 'SELECT COUNT(*) FROM ' || rec.schema_name || '.' || rec.table_name ||
                     ' WHERE resource_id = :1 AND ' || v_bu_column || ' = :2';
            
            EXECUTE IMMEDIATE v_sql INTO v_count USING p_resource_id, p_business_unit;
            
            IF v_count > 0 THEN
                IF LENGTH(v_results_sql) > 100 THEN
                    v_results_sql := v_results_sql || ' UNION ALL ';
                END IF;
                v_results_sql := v_results_sql || 
                    'SELECT ''' || rec.schema_name || ''' AS schema_name, ' ||
                    '''' || rec.table_name || ''' AS table_name, ' ||
                    '''' || v_bu_column || ''' AS business_unit_column, ' ||
                    TO_CHAR(v_count) || ' AS row_count FROM dual';
            END IF;
            
        EXCEPTION
            WHEN OTHERS THEN
                NULL;
        END;
    END LOOP;
    
    v_results_sql := v_results_sql || ') ORDER BY schema_name, table_name';
    
    OPEN p_result_cursor FOR v_results_sql;
    
END find_resource_tables_cursor;
/

-- Example usage:
-- 
-- Method 1: Using DBMS_OUTPUT
-- SET SERVEROUTPUT ON;
-- EXEC find_resource_tables('RESOURCE123', 'BU001', USER, 'N');
--
-- Method 2: Using cursor (for applications)
-- DECLARE
--   v_cursor SYS_REFCURSOR;
--   v_schema VARCHAR2(128);
--   v_table VARCHAR2(128);
--   v_bu_col VARCHAR2(128);
--   v_count NUMBER;
-- BEGIN
--   find_resource_tables_cursor('RESOURCE123', 'BU001', USER, 'N', v_cursor);
--   LOOP
--     FETCH v_cursor INTO v_schema, v_table, v_bu_col, v_count;
--     EXIT WHEN v_cursor%NOTFOUND;
--     DBMS_OUTPUT.PUT_LINE(v_schema || '.' || v_table || ' - ' || v_bu_col || ' - ' || v_count);
--   END LOOP;
--   CLOSE v_cursor;
-- END;
/


