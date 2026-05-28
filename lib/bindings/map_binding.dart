import 'package:falcon_one_demo/controllers/glasses_controller.dart';
import 'package:falcon_one_demo/controllers/map_controller.dart';
import 'package:falcon_one_demo/services/glasses_service.dart';
import 'package:get/get.dart';

class MapBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut<GlassesService>(() => GlassesService());
    Get.lazyPut<GlassesController>(() => GlassesController());
    Get.lazyPut<MapController>(() => MapController());
  }
}
