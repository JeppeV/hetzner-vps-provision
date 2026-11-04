"""Offline validation and reconnect wiring tests; never open a connection."""

import itertools
from pathlib import Path
import unittest

from ansible.parsing.dataloader import DataLoader
from ansible.template import Templar, trust_as_template


ROLE = Path(__file__).resolve().parents[1] / "roles/baseline"


class BaselineWiringTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.loader = DataLoader()
        cls.validation = cls.loader.load_from_file(str(ROLE / "tasks/validate.yml"))
        cls.ufw = cls.loader.load_from_file(str(ROLE / "tasks/ufw.yml"))[0]
        cls.fail2ban = cls.loader.load_from_file(str(ROLE / "tasks/fail2ban.yml"))
        cls.handlers = cls.loader.load_from_file(str(ROLE / "handlers/main.yml"))
        cls.reconnect = cls.loader.load_from_file(str(ROLE / "tasks/reconnect.yml"))

    def evaluate(self, conditions, variables):
        templar = Templar(loader=self.loader, variables=variables)
        if not isinstance(conditions, list):
            conditions = [conditions]
        return all(templar.evaluate_conditional(trust_as_template(condition)) for condition in conditions)

    def test_journal_limits_reject_invalid_sizes(self):
        conditions = self.validation[1]["ansible.builtin.assert"]["that"]
        for value in ("256M", "1G", "64K", "0M", "-1G", "256", "unlimited", ""):
            for field in ("baseline_journal_max_use", "baseline_journal_keep_free"):
                with self.subTest(value=value, field=field):
                    variables = {"baseline_journal_max_use": "256M", "baseline_journal_keep_free": "512M"}
                    variables[field] = value
                    self.assertEqual(self.evaluate(conditions, variables), value in ("256M", "1G", "64K"))

    def test_reconnect_always_resets_before_waiting_without_meta_conditionals(self):
        self.assertEqual(len(self.reconnect), 2)
        self.assertEqual(self.reconnect[0]["ansible.builtin.meta"], "reset_connection")
        self.assertNotIn("when", self.reconnect[0])
        self.assertEqual(self.reconnect[1]["ansible.builtin.wait_for_connection"]["timeout"], 120)
        self.assertIs(self.reconnect[1]["become"], False)

    def test_ufw_reconnect_is_dynamically_guarded_by_check_mode_and_changes(self):
        reconnect = self.ufw["block"][-1]
        self.assertEqual(reconnect["ansible.builtin.include_tasks"], "reconnect.yml")
        results = [task["register"] for task in self.ufw["block"] if "register" in task]
        for check_mode in (False, True):
            for changes in itertools.product((False, True), repeat=len(results)):
                variables = dict(zip(results, ({"changed": changed} for changed in changes)))
                variables["ansible_check_mode"] = check_mode
                selected = self.evaluate(self.ufw["when"], variables) and self.evaluate(reconnect["when"], variables)
                self.assertEqual(selected, not check_mode and any(changes))

    def test_fail2ban_reconnect_is_dynamically_guarded(self):
        reconnect = next(task for task in self.fail2ban if task.get("ansible.builtin.include_tasks") == "reconnect.yml")
        for check_mode, changed in itertools.product((False, True), repeat=2):
            self.assertEqual(self.evaluate(reconnect["when"], {
                "ansible_check_mode": check_mode,
                "baseline_fail2ban_service": {"changed": changed},
            }), not check_mode and changed)

    def test_ssh_handlers_do_not_reload_or_reconnect_in_check_mode(self):
        handlers = [task for task in self.handlers if task.get("listen") == "Apply SSH configuration"]
        self.assertEqual(len(handlers), 2)
        self.assertEqual(handlers[1]["ansible.builtin.include_tasks"], "../tasks/reconnect.yml")
        for task in handlers:
            self.assertFalse(self.evaluate(task["when"], {"ansible_check_mode": True}))
            self.assertTrue(self.evaluate(task["when"], {"ansible_check_mode": False}))


if __name__ == "__main__":
    unittest.main()
