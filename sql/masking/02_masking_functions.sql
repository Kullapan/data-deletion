-- =============================================================================
-- Data Masking System: Reusable Masking Function Library
-- Engine: PostgreSQL 16+
-- Provides standard PII transformation routines callable directly from 
-- the configuration table (masking_rule.mask_expression).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Email Masking: Preserves first and last char of user, masks domain prefix
-- Example: john.doe@company.com -> j***e@c******.com
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_mask_email(val TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    user_part TEXT;
    domain_part TEXT;
    domain_name TEXT;
    domain_tld TEXT;
    at_pos INT;
    dot_pos INT;
BEGIN
    IF val IS NULL OR val = '' THEN
        RETURN val;
    END IF;

    at_pos := position('@' IN val);
    IF at_pos <= 1 THEN
        RETURN '***@***.***';
    END IF;

    user_part := substring(val FROM 1 FOR at_pos - 1);
    domain_part := substring(val FROM at_pos + 1);

    -- Mask user part: keep first and last char
    IF length(user_part) <= 2 THEN
        user_part := substring(user_part FROM 1 FOR 1) || '***';
    ELSE
        user_part := substring(user_part FROM 1 FOR 1) || '***' || substring(user_part FROM length(user_part) FOR 1);
    END IF;

    -- Mask domain name before TLD
    dot_pos := position('.' IN domain_part);
    IF dot_pos > 1 THEN
        domain_name := substring(domain_part FROM 1 FOR dot_pos - 1);
        domain_tld := substring(domain_part FROM dot_pos);
        IF length(domain_name) <= 2 THEN
            domain_name := substring(domain_name FROM 1 FOR 1) || '***';
        ELSE
            domain_name := substring(domain_name FROM 1 FOR 1) || '******';
        END IF;
        domain_part := domain_name || domain_tld;
    ELSE
        domain_part := '******.com';
    END IF;

    RETURN user_part || '@' || domain_part;
END;
$$;

COMMENT ON FUNCTION fn_mask_email IS 'Masks email address while preserving RFC format for validation tests';

-- -----------------------------------------------------------------------------
-- 2. Phone Number Masking: Preserves prefix and last 4 digits
-- Example: 0812345678 -> 081-XXX-5678
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_mask_phone(val TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    clean_val TEXT;
    len INT;
BEGIN
    IF val IS NULL OR val = '' THEN
        RETURN val;
    END IF;

    clean_val := regexp_replace(val, '[^0-9+]', '', 'g');
    len := length(clean_val);

    IF len < 7 THEN
        RETURN 'XXX-XXXX';
    ELSIF len = 10 THEN
        -- Standard 10-digit mobile (e.g. 081-XXX-5678)
        RETURN substring(clean_val FROM 1 FOR 3) || '-XXX-' || substring(clean_val FROM 7 FOR 4);
    ELSIF len = 9 THEN
        -- 9-digit landline (e.g. 02-XXX-5678)
        RETURN substring(clean_val FROM 1 FOR 2) || '-XXX-' || substring(clean_val FROM 6 FOR 4);
    ELSE
        -- International or arbitrary format
        RETURN substring(clean_val FROM 1 FOR 3) || '-XXXX-' || substring(clean_val FROM len - 3 FOR 4);
    END IF;
END;
$$;

COMMENT ON FUNCTION fn_mask_phone IS 'Masks phone numbers preserving area code and last 4 digits';

-- -----------------------------------------------------------------------------
-- 3. Citizen / National ID Masking: 13-digit format
-- Example: 1100500123456 -> 1-1005-XXXXX-56
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_mask_citizen_id(val TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    clean_val TEXT;
BEGIN
    IF val IS NULL OR val = '' THEN
        RETURN val;
    END IF;

    clean_val := regexp_replace(val, '[^0-9]', '', 'g');

    IF length(clean_val) = 13 THEN
        RETURN substring(clean_val FROM 1 FOR 1) || '-' ||
               substring(clean_val FROM 2 FOR 4) || '-XXXXX-' ||
               substring(clean_val FROM 11 FOR 2);
    ELSE
        -- Generic masking for other lengths
        RETURN substring(clean_val FROM 1 FOR 2) || 'XXXXXXX' || substring(clean_val FROM length(clean_val) - 1 FOR 2);
    END IF;
END;
$$;

COMMENT ON FUNCTION fn_mask_citizen_id IS 'Masks National ID / Citizen ID numbers to privacy compliant pattern';

-- -----------------------------------------------------------------------------
-- 4. Credit Card Masking (PCI-DSS Standard):
-- Example: 4111111111111234 -> XXXX-XXXX-XXXX-1234
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_mask_credit_card(val TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    clean_val TEXT;
    len INT;
BEGIN
    IF val IS NULL OR val = '' THEN
        RETURN val;
    END IF;

    clean_val := regexp_replace(val, '[^0-9]', '', 'g');
    len := length(clean_val);

    IF len >= 12 THEN
        RETURN 'XXXX-XXXX-XXXX-' || substring(clean_val FROM len - 3 FOR 4);
    ELSE
        RETURN 'XXXX-XXXX';
    END IF;
END;
$$;

COMMENT ON FUNCTION fn_mask_credit_card IS 'Compliant PCI-DSS credit card masking keeping only last 4 digits';

-- -----------------------------------------------------------------------------
-- 5. Name Masking: Preserves initial letter of each word
-- Example: Somchai Prasert -> S****** P******
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_mask_name(val TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    words TEXT[];
    w TEXT;
    masked_words TEXT[] := '{}';
BEGIN
    IF val IS NULL OR val = '' THEN
        RETURN val;
    END IF;

    words := string_to_array(btrim(val), ' ');
    FOREACH w IN ARRAY words LOOP
        IF length(w) > 0 THEN
            masked_words := array_append(masked_words, substring(w FROM 1 FOR 1) || repeat('*', GREATEST(length(w) - 1, 3)));
        END IF;
    END LOOP;

    RETURN array_to_string(masked_words, ' ');
END;
$$;

COMMENT ON FUNCTION fn_mask_name IS 'Masks personal names while keeping initials';

-- -----------------------------------------------------------------------------
-- 6. Deterministic Salted Hash (Preserves joins across tables!)
-- Example: John Doe -> 'HASH_' || substring(sha256, 1, 12)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_mask_salted_hash(val TEXT, salt TEXT DEFAULT 'MASKING_SALT_2026')
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF val IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN 'MSK_' || substring(encode(sha256((val || COALESCE(salt, ''))::bytea), 'hex') FROM 1 FOR 12);
END;
$$;

COMMENT ON FUNCTION fn_mask_salted_hash IS 'Deterministic hash pseudonym preserving cross-table join integrity';

-- -----------------------------------------------------------------------------
-- 7. Generic Partial Masking:
-- Example: fn_mask_partial('1234567890', 2, 2, '*') -> '12******90'
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_mask_partial(
    val TEXT,
    keep_start INT DEFAULT 2,
    keep_end INT DEFAULT 2,
    mask_char CHAR(1) DEFAULT '*'
)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    len INT;
    mask_len INT;
BEGIN
    IF val IS NULL OR val = '' THEN
        RETURN val;
    END IF;

    len := length(val);
    IF len <= (keep_start + keep_end) THEN
        RETURN repeat(mask_char, len);
    END IF;

    mask_len := len - keep_start - keep_end;
    RETURN substring(val FROM 1 FOR keep_start) ||
           repeat(mask_char, mask_len) ||
           substring(val FROM len - keep_end + 1 FOR keep_end);
END;
$$;

COMMENT ON FUNCTION fn_mask_partial IS 'General purpose partial redaction keeping N start and M end characters';

-- -----------------------------------------------------------------------------
-- 8. Date Shifting: Shifts date by random days within range
-- Example: Shifts date by between -30 and +30 days
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_mask_date_shift(
    val TIMESTAMPTZ,
    min_days INT DEFAULT -30,
    max_days INT DEFAULT 30
)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    shift_days INT;
BEGIN
    IF val IS NULL THEN
        RETURN NULL;
    END IF;

    -- Deterministic pseudo-random shift based on date itself
    shift_days := min_days + (abs(hashtext(val::text)) % (max_days - min_days + 1));
    RETURN val + (shift_days || ' days')::INTERVAL;
END;
$$;

COMMENT ON FUNCTION fn_mask_date_shift IS 'Shifts date while preserving seasonality and distribution';
