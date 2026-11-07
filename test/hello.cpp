// Проверка libstdc++: строки, контейнеры, исключения, std::thread.
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

int main()
{
	std::map<std::string, int> m{{"EE", 5900}, {"IOP", 3000}};
	std::vector<std::thread> ts;
	int sum = 0;
	for (int i = 1; i <= 3; i++)
		ts.emplace_back([&sum, i] { sum += i; }), ts.back().join();
	try {
		throw std::runtime_error("исключения работают");
	} catch (const std::exception &e) {
		std::cout << "C++: " << e.what() << ", EE=R" << m["EE"]
			  << ", sum=" << sum << std::endl;
	}
	return sum == 6 ? 0 : 1;
}
