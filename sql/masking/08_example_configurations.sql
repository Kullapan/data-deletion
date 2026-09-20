-- =============================================================================
-- Data Masking System: Example Enterprise Configurations
-- Demonstrates how masking logic (functions, SQL expressions, static values)
-- is configured directly in the masking_rule table.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Scenario 1: Customer Personal Identifiable Information (PII) Masking
-- Key Type: CUSTOMER_ID (provided in Excel)
-- Target Tables: customers, customer_contacts
-- -----------------------------------------------------------------------------
INSERT INTO masking_group (group_code, key_type, description, chunk_size, throttle_sec, is_active)
VALUES (
    'CUST_PII',
    'CUSTOMER_ID',
    'PDPA Right-to-be-Forgotten / Anonymization of Customer PII records',
    500,
    0.05,
    TRUE
)
ON CONFLICT (group_code) DO UPDATE 
SET key_type = EXCLUDED.key_type, description = EXCLUDED.description;

INSERT INTO masking_rule (group_code, target_table, column_name, mask_expression, execution_order, where_clause_template)
VALUES
    -- 1. Mask Email using helper function
    ('CUST_PII', 'customers', 'email', 'fn_mask_email(email)', 1, 'WHERE customer_id = ANY($1)'),
    
    -- 2. Mask Phone Number preserving prefix and suffix
    ('CUST_PII', 'customers', 'phone_number', 'fn_mask_phone(phone_number)', 1, 'WHERE customer_id = ANY($1)'),
    
    -- 3. Mask Citizen / National ID
    ('CUST_PII', 'customers', 'citizen_id', 'fn_mask_citizen_id(citizen_id)', 1, 'WHERE customer_id = ANY($1)'),
    
    -- 4. Mask Customer Name preserving initials
    ('CUST_PII', 'customers', 'customer_name', 'fn_mask_name(customer_name)', 1, 'WHERE customer_id = ANY($1)'),
    
    -- 5. Mask Address with dynamic SQL expression
    ('CUST_PII', 'customers', 'address', '''REDACTED_ADDR_'' || LPAD(id::text, 6, ''0'')', 1, 'WHERE customer_id = ANY($1)')
ON CONFLICT (group_code, target_table, column_name) DO UPDATE
SET mask_expression = EXCLUDED.mask_expression,
    where_clause_template = EXCLUDED.where_clause_template;

-- -----------------------------------------------------------------------------
-- Scenario 2: Employee HR Data Masking (Salary Noise + Partial Redaction)
-- Key Type: EMPLOYEE_ID
-- -----------------------------------------------------------------------------
INSERT INTO masking_group (group_code, key_type, description, chunk_size, throttle_sec, is_active)
VALUES (
    'EMP_CONFIDENTIAL',
    'EMPLOYEE_ID',
    'Sanitizing employee salary and confidential info for QA staging environment',
    200,
    0.05,
    TRUE
)
ON CONFLICT (group_code) DO UPDATE 
SET key_type = EXCLUDED.key_type, description = EXCLUDED.description;

INSERT INTO masking_rule (group_code, target_table, column_name, mask_expression, execution_order, where_clause_template)
VALUES
    -- Bank Account: Keep first 3 and last 3 digits, mask rest with 'X'
    ('EMP_CONFIDENTIAL', 'employees', 'bank_account_no', 'fn_mask_partial(bank_account_no, 3, 3, ''X'')', 1, 'WHERE emp_id = ANY($1)'),
    
    -- Date of birth: Shift by +/- 45 days to protect exact age
    ('EMP_CONFIDENTIAL', 'employees', 'birth_date', 'fn_mask_date_shift(birth_date::timestamptz, -45, 45)::date', 1, 'WHERE emp_id = ANY($1)'),
    
    -- Salary: Perturb by +/- 15% noise
    ('EMP_CONFIDENTIAL', 'employees', 'salary', 'ROUND(salary * (0.85 + (abs(hashtext(emp_id::text)) % 30) / 100.0), -2)', 1, 'WHERE emp_id = ANY($1)')
ON CONFLICT (group_code, target_table, column_name) DO UPDATE
SET mask_expression = EXCLUDED.mask_expression,
    where_clause_template = EXCLUDED.where_clause_template;

-- -----------------------------------------------------------------------------
-- Scenario 3: Deterministic Salted Hash (Cross-Table Join Preservation)
-- Key Type: USERNAME
-- -----------------------------------------------------------------------------
INSERT INTO masking_group (group_code, key_type, description, chunk_size, throttle_sec, is_active)
VALUES (
    'USER_ANONYMIZE',
    'USERNAME',
    'Anonymizing usernames with deterministic salted hashing so reports can still join',
    1000,
    0.02,
    TRUE
)
ON CONFLICT (group_code) DO UPDATE 
SET key_type = EXCLUDED.key_type, description = EXCLUDED.description;

INSERT INTO masking_rule (group_code, target_table, column_name, mask_expression, execution_order, where_clause_template)
VALUES
    ('USER_ANONYMIZE', 'app_users', 'username', 'fn_mask_salted_hash(username, ''PROD_SALT_KEY_2026'')', 1, 'WHERE username = ANY($1)'),
    ('USER_ANONYMIZE', 'audit_events', 'actor_name', 'fn_mask_salted_hash(actor_name, ''PROD_SALT_KEY_2026'')', 1, 'WHERE actor_name = ANY($1)')
ON CONFLICT (group_code, target_table, column_name) DO UPDATE
SET mask_expression = EXCLUDED.mask_expression,
    where_clause_template = EXCLUDED.where_clause_template;
