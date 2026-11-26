#!/usr/bin/env python3
"""Verify Package A in a disposable local PostgreSQL container; no hosted writes."""
import argparse
import json
from pathlib import Path
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = """
INSERT INTO library.membership_type VALUES (1001,'Regular',2,0.25),(1002,'Student',1,0);
INSERT INTO library.client VALUES
 (1001,'Alex','Rivera','555-0101',1001,'active'),
 (1002,'Sam','Chen','555-0102',1001,'active'),
 (1003,'Lee','Patel','555-0103',1001,'active');
INSERT INTO library.library_item (item_id,title,item_type,author_creator,publication_year,genre,isbn)
VALUES (1001,'Dune','book','Frank Herbert',1965,'Science fiction','9780441172719'),
 (1002,'Dune second copy','book','Frank Herbert',1965,'Science fiction','9780441172719'),
 (1003,'A recording','digital_media','Example Creator',2020,'Education',NULL),
 (1004,'A fourth item','book','Example Author',2021,'History',NULL);
INSERT INTO library.library_item (item_id,title,item_type,issue_number,publication_date)
VALUES (1005,'Science Monthly','magazine','November 2025','2025-11-01');
"""
BORROW = "SELECT library.checkout_item(1001,1001,'2025-01-01 12:00-06','2025-01-15');"
HOLD = BORROW + "SELECT library.reserve_item(1002,1001,'2025-01-02');"
QUEUE = HOLD + "SELECT library.reserve_item(1003,1001,'2025-01-03');"
RETURN = "SELECT library.return_item((SELECT loan_id FROM library.loan WHERE item_id=1001),'2025-01-18 12:00-06');"
PAID = BORROW + RETURN + "SELECT library.pay_late_fee((SELECT fee_id FROM library.late_fee),0.25);"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', default='postgres:17-alpine')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    container = 'library447-verify-' + uuid.uuid4().hex[:10]
    results = []
    started = time.monotonic()

    def run(sql, check=False):
        return subprocess.run(
            ['docker','exec','-i',container,'psql','-X','-qAt','-v','ON_ERROR_STOP=1',
             '-v','VERBOSITY=verbose','-U','postgres','-d','library_test'],
            input=sql, text=True, capture_output=True, check=check, timeout=30)

    def case(name, sql, expected=None, error=None, fixture=True):
        result = run('BEGIN;\n' + (FIXTURE if fixture else '') + '\n' + sql + '\nROLLBACK;')
        last = result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ''
        passed = (result.returncode != 0 and error in result.stderr) if error else (
            result.returncode == 0 and (expected is None or last == str(expected)))
        row = {'name': name, 'passed': passed}
        if not passed:
            row.update(expected=error or expected, actual=last, error=result.stderr[-1800:])
        results.append(row)

    try:
        subprocess.run(['docker','run','--rm','-d','--name',container,
                        '-e','POSTGRES_PASSWORD=local-verification-only',
                        '-e','POSTGRES_DB=library_test',args.image], check=True, capture_output=True, timeout=60)
        for _ in range(100):
            ready = subprocess.run(['docker','exec',container,'pg_isready','-h','127.0.0.1','-U','postgres','-d','library_test'], capture_output=True)
            if ready.returncode == 0:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError('Local PostgreSQL did not become ready')
        for filename in ('01_schema.sql','02_operations.sql'):
            run((ROOT / 'sql' / filename).read_text(), check=True)

        case('seven tables', "SELECT count(*) FROM pg_tables WHERE schemaname='library';", 7, fixture=False)
        case('RLS on every table', "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='library' AND c.relkind='r' AND c.relrowsecurity;", 7, fixture=False)
        case('no security definer functions', "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='library' AND p.prosecdef;", 0, fixture=False)
        case('no public function execute', "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a WHERE n.nspname='library' AND a.grantee=0 AND a.privilege_type='EXECUTE';", 0, fixture=False)
        for name, sql, state in [
            ('positive identifiers', "INSERT INTO library.membership_type VALUES (0,'Invalid',1,0);", '23514'),
            ('blank policy name', "UPDATE library.membership_type SET name=' ' WHERE membership_type_id=1001;", '23514'),
            ('negative limit', "UPDATE library.membership_type SET borrowing_limit=-1 WHERE membership_type_id=1001;", '23514'),
            ('negative rate', "UPDATE library.membership_type SET daily_late_fee_rate=-1 WHERE membership_type_id=1001;", '23514'),
            ('NaN rate', "UPDATE library.membership_type SET daily_late_fee_rate='NaN' WHERE membership_type_id=1001;", '23514'),
            ('membership FK', "UPDATE library.client SET membership_type_id=9999 WHERE client_id=1001;", '23503'),
            ('blank client name', "UPDATE library.client SET first_name=' ' WHERE client_id=1001;", '23514'),
            ('invalid account status', "UPDATE library.client SET account_status='unknown' WHERE client_id=1001;", '23514'),
            ('invalid item type', "UPDATE library.library_item SET item_type='other' WHERE item_id=1001;", '23514'),
            ('book requires author', "UPDATE library.library_item SET author_creator=NULL WHERE item_id=1001;", '23514'),
            ('book requires publication year', "UPDATE library.library_item SET publication_year=NULL WHERE item_id=1001;", '23514'),
            ('book requires genre', "UPDATE library.library_item SET genre=' ' WHERE item_id=1001;", '23514'),
            ('magazine requires issue', "UPDATE library.library_item SET issue_number=NULL WHERE item_id=1005;", '23514'),
            ('subtype fields cannot mix', "UPDATE library.library_item SET issue_number='1' WHERE item_id=1001;", '23514'),
            ('normalized ISBN', "UPDATE library.library_item SET isbn='not-an-isbn' WHERE item_id=1001;", '23514'),
            ('availability cannot be forged', "UPDATE library.library_item SET availability_status='on_loan' WHERE item_id=1001;", '23514'),
            ('unknown client', "SELECT library.checkout_item(9999,1001);", '23503'),
            ('unknown item', "SELECT library.checkout_item(1001,9999);", '23503'),
            ('restricted account', "UPDATE library.client SET account_status='restricted' WHERE client_id=1001;" + BORROW, '23514'),
            ('inactive account', "UPDATE library.client SET account_status='inactive' WHERE client_id=1001;" + BORROW, '23514'),
            ('restricted item', "UPDATE library.library_item SET borrowing_restricted=true WHERE item_id=1001;" + BORROW, '23514'),
            ('due date ordering', "SELECT library.checkout_item(1001,1001,'2025-01-02 12:00-06','2025-01-01');", '23514'),
            ('return ordering', BORROW + "SELECT library.return_item((SELECT loan_id FROM library.loan),'2024-12-31 12:00-06');", '23514'),
            ('duplicate active loan', BORROW + "SELECT library.checkout_item(1002,1001);", '23514'),
            ('zero borrowing limit', "UPDATE library.membership_type SET borrowing_limit=0 WHERE membership_type_id=1001;" + BORROW, '23514'),
            ('borrowing limit via direct inserts', BORROW + "SELECT library.checkout_item(1001,1002); INSERT INTO library.loan(client_id,item_id,due_date) VALUES(1001,1003,current_date+14);", '23514'),
            ('freeze active fee rate', BORROW + "UPDATE library.membership_type SET daily_late_fee_rate=1 WHERE membership_type_id=1001;", '23514'),
            ('freeze active membership', BORROW + "UPDATE library.client SET membership_type_id=1002 WHERE client_id=1001;", '23514'),
            ('cannot lower limit under active count', BORROW + "UPDATE library.membership_type SET borrowing_limit=0 WHERE membership_type_id=1001;", '23514'),
            ('cannot delete active loan', BORROW + "DELETE FROM library.loan;", '23514'),
            ('cannot delete referenced item', BORROW + "DELETE FROM library.library_item WHERE item_id=1001;", '23503'),
            ('cannot delete referenced client', BORROW + "DELETE FROM library.client WHERE client_id=1001;", '23503'),
            ('cannot delete referenced membership', "DELETE FROM library.membership_type WHERE membership_type_id=1001;", '23503'),
            ('reserve only unavailable item', "SELECT library.reserve_item(1002,1001);", '23514'),
            ('cannot reserve own loan', BORROW + "SELECT library.reserve_item(1001,1001);", '23514'),
            ('duplicate open reservation', HOLD + "SELECT library.reserve_item(1002,1001);", '23505'),
            ('reservation starts pending', BORROW + "INSERT INTO library.reservation(client_id,item_id,reservation_status) VALUES(1002,1001,'available');", '23514'),
            ('cannot fulfill pending hold', HOLD + "UPDATE library.reservation SET reservation_status='fulfilled';", '23514'),
            ('cannot deactivate open hold client', HOLD + "UPDATE library.client SET account_status='inactive' WHERE client_id=1002;", '23514'),
            ('cannot restrict held item', HOLD + "UPDATE library.library_item SET borrowing_restricted=true WHERE item_id=1001;", '23514'),
            ('cannot delete open reservation', HOLD + "DELETE FROM library.reservation;", '23514'),
            ('hold blocks other borrower', HOLD + RETURN + "SELECT library.checkout_item(1003,1001);", '23514'),
            ('terminal reservation cannot reopen', HOLD + "SELECT library.cancel_reservation((SELECT reservation_id FROM library.reservation)); UPDATE library.reservation SET reservation_status='pending';", '23514'),
            ('double return rejected', BORROW + RETURN + RETURN, '23514'),
            ('closed loan cannot reopen', BORROW + RETURN + "UPDATE library.loan SET return_timestamp=NULL;", '23514'),
            ('loan client immutable', BORROW + "UPDATE library.loan SET client_id=1002;", '23514'),
            ('negative fee', BORROW + "INSERT INTO library.late_fee(loan_id,amount_owed) SELECT loan_id,-1 FROM library.loan;", '23514'),
            ('NaN fee', BORROW + "INSERT INTO library.late_fee(loan_id,amount_owed) SELECT loan_id,'NaN'::numeric FROM library.loan;", '23514'),
            ('fee uniqueness', BORROW + RETURN + "INSERT INTO library.late_fee(loan_id,amount_owed) SELECT loan_id,1 FROM library.loan;", '23505'),
            ('overpayment rejected', PAID + "SELECT library.pay_late_fee((SELECT fee_id FROM library.late_fee),1);", '23514'),
            ('fractional-cent payment rejected', BORROW + RETURN + "SELECT library.pay_late_fee((SELECT fee_id FROM library.late_fee),0.001);", '23514'),
            ('wrong loan notification client', BORROW + "INSERT INTO library.notification(client_id,loan_id,notification_type,message) SELECT 1002,loan_id,'overdue','Example' FROM library.loan;", '23514'),
            ('wrong hold notification client', HOLD + RETURN + "UPDATE library.notification SET client_id=1003;", '23514'),
            ('notification needs event', "INSERT INTO library.notification(client_id,notification_type,message) VALUES(1001,'overdue','Example');", '23514'),
        ]:
            case(name, sql, error=state)

        case('repeated ISBN and optional ISBN allowed', 'SELECT count(*) FROM library.library_item;', 5)
        case('ordinary client and item maintenance', "UPDATE library.client SET phone_number='+1 555 123 ext 4' WHERE client_id=1001; UPDATE library.library_item SET title='Revised title' WHERE item_id=1004; DELETE FROM library.library_item WHERE item_id=1004; SELECT count(*) FROM library.library_item;", 4)
        case('default loan period', "SELECT library.checkout_item(1001,1001,'2025-01-01 12:00-06'); SELECT due_date FROM library.loan;", '2025-01-15')
        case('checkout updates availability', BORROW + 'SELECT availability_status FROM library.library_item WHERE item_id=1001;', 'on_loan')
        case('Chicago dates independent of session timezone', "SET LOCAL TIME ZONE 'Asia/Tokyo'; SELECT library.checkout_item(1001,1001,'2025-01-02 02:00+00','2025-01-01'); SELECT due_date FROM library.loan;", '2025-01-01')
        case('due day has no late fee', BORROW + "SELECT library.assess_late_fee((SELECT loan_id FROM library.loan),'2025-01-15');", '0.00')
        case('active late fee calculation', BORROW + "SELECT library.assess_late_fee((SELECT loan_id FROM library.loan),'2025-01-19');", '1.00')
        case('return computes three-day fee', BORROW + RETURN, '0.75')
        case('returned fee stops accruing', BORROW + RETURN + "SELECT library.assess_late_fee((SELECT loan_id FROM library.loan),'2025-03-01');", '0.75')
        case('payment remaining balance', PAID, '0.50')
        case('return releases availability', BORROW + RETURN + "SELECT availability_status FROM library.library_item WHERE item_id=1001;", 'available')
        case('restricted client can still return', BORROW + "UPDATE library.client SET account_status='restricted' WHERE client_id=1001;" + RETURN, '0.75')
        case('FIFO reservation promotion and notice', QUEUE + RETURN + "SELECT concat(r.client_id,':',i.availability_status,':',(SELECT count(*) FROM library.notification)) FROM library.reservation r JOIN library.library_item i USING(item_id) WHERE r.reservation_status='available';", '1002:reserved:1')
        case('cancelling head promotes next', QUEUE + RETURN + "SELECT library.cancel_reservation((SELECT reservation_id FROM library.reservation WHERE client_id=1002)); SELECT client_id FROM library.reservation WHERE reservation_status='available';", 1003)
        case('cancelling pending leaves borrower intact', HOLD + "SELECT library.cancel_reservation((SELECT reservation_id FROM library.reservation)); SELECT availability_status FROM library.library_item WHERE item_id=1001;", 'on_loan')
        case('held checkout fulfills reservation', HOLD + RETURN + "SELECT library.checkout_item(1002,1001); SELECT reservation_status FROM library.reservation;", 'fulfilled')
        case('notification batch idempotent', BORROW + "SELECT library.generate_notifications('2025-01-14'); SELECT library.generate_notifications('2025-01-14');", 0)
        case('due soon and overdue notification types', BORROW + "SELECT library.generate_notifications('2025-01-14'); SELECT library.generate_notifications('2025-01-16'); SELECT string_agg(notification_type,',' ORDER BY notification_type) FROM library.notification;", 'overdue,upcoming_due')
        case('on-time return has no fee record', BORROW + "SELECT library.return_item((SELECT loan_id FROM library.loan),'2025-01-15 23:00-06'); SELECT count(*) FROM library.late_fee;", 0)
        case('zero rate has zero charge', "UPDATE library.client SET membership_type_id=1002 WHERE client_id=1001;" + BORROW + RETURN, '0.00')
        case('closed fee survives later rate changes', BORROW + RETURN + "UPDATE library.membership_type SET daily_late_fee_rate=1 WHERE membership_type_id=1001; SELECT library.assess_late_fee((SELECT loan_id FROM library.loan),'2025-03-01');", '0.75')
        case('closed fee survives later membership changes', BORROW + RETURN + "UPDATE library.client SET membership_type_id=1002 WHERE client_id=1001; SELECT library.assess_late_fee((SELECT loan_id FROM library.loan),'2025-03-01');", '0.75')
        case('first return finalizes provisional assessment', BORROW + "SELECT library.assess_late_fee((SELECT loan_id FROM library.loan),'2025-01-16');" + RETURN, '0.75')
        case('zero-rate late fee stays finalized', "UPDATE library.client SET membership_type_id=1002 WHERE client_id=1001;" + BORROW + RETURN + "UPDATE library.membership_type SET daily_late_fee_rate=2 WHERE membership_type_id=1002; SELECT library.assess_late_fee((SELECT loan_id FROM library.loan),'2025-03-01');", '0.00')
        case('overpaid backdated return rejected atomically', BORROW + "SELECT library.assess_late_fee((SELECT loan_id FROM library.loan),'2025-01-19'); SELECT library.pay_late_fee((SELECT fee_id FROM library.late_fee),1); SELECT library.return_item((SELECT loan_id FROM library.loan),'2025-01-16 12:00-06');", error='23514')

        # A waiting transaction must re-check both item and membership eligibility.
        for mode in ('same_item', 'same_client_limit'):
            run(FIXTURE, check=True)
            if mode == 'same_client_limit':
                run('UPDATE library.membership_type SET borrowing_limit=1 WHERE membership_type_id=1001;', check=True)
            holder = subprocess.Popen(
                ['docker','exec','-i',container,'psql','-X','-qAt','-v','ON_ERROR_STOP=1','-U','postgres','-d','library_test'],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            holder.stdin.write('BEGIN;'+BORROW+"SELECT pg_sleep(2); COMMIT;\n")
            holder.stdin.close()
            for _ in range(100):
                state = run("SELECT count(*) FROM pg_stat_activity WHERE wait_event='PgSleep';", check=True)
                if state.stdout.strip() == '1':
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError('Concurrency holder did not reach the locked state')
            competing = 'SELECT library.checkout_item(1002,1001);' if mode == 'same_item' else 'SELECT library.checkout_item(1001,1002);'
            outcome = run(competing)
            holder.wait(timeout=20)
            count = run('SELECT count(*) FROM library.loan WHERE return_timestamp IS NULL;', check=True).stdout.strip()
            results.append({'name': 'concurrent '+mode, 'passed': holder.returncode == 0 and outcome.returncode != 0 and '23514' in outcome.stderr and count == '1'})
            run('TRUNCATE library.notification,library.late_fee,library.reservation,library.loan,library.library_item,library.client,library.membership_type;', check=True)

        report = {'database': run('SELECT version();', check=True).stdout.strip(),
                  'passed': sum(r['passed'] for r in results), 'total': len(results),
                  'failures': [r for r in results if not r['passed']],
                  'elapsed_seconds': round(time.monotonic()-started, 2)}
        if args.output:
            args.output.write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(report, indent=2))
        return 0 if not report['failures'] else 1
    finally:
        subprocess.run(['docker','rm','-f',container], capture_output=True)


if __name__ == '__main__':
    raise SystemExit(main())
